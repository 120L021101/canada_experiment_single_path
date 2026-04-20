#!/usr/bin/env bash
# ============================================================
# run_measurement.sh — Single-path network measurement driver
#
# Runs on the SUBSCRIBER machine (Finland).
# 1. Starts UDP echo server on relay (Germany) via SSH
# 2. Runs measurement Docker container locally (RTT + traceroute)
# 3. Collects results
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# ── Load config ──────────────────────────────────────────────
source experiment.env

# ── Parse arguments ──────────────────────────────────────────
START_RUN=1
END_RUN="$TOTAL_RUNS"
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --start)      START_RUN="$2";      shift 2 ;;
        --end)        END_RUN="$2";        shift 2 ;;
        --interface)  SUB_INTERFACE="$2";  shift 2 ;;
        --dry-run)    DRY_RUN=true;        shift   ;;
        *)            echo "Unknown arg: $1"; exit 1 ;;
    esac
done

# ── Helper functions ─────────────────────────────────────────

log() { echo "[$(date '+%H:%M:%S')] $*"; }
log_err() { echo "[$(date '+%H:%M:%S')] ERROR: $*" >&2; }

CLOUDFLARED_BIN=""

ensure_cloudflared() {
    if [[ -n "$CLOUDFLARED_BIN" && -x "$CLOUDFLARED_BIN" ]]; then
        return 0
    fi
    if command -v cloudflared >/dev/null 2>&1; then
        CLOUDFLARED_BIN="$(command -v cloudflared)"
        return 0
    fi
    log "  cloudflared not found, installing..."
    local raw_arch="$(uname -m)"
    local arch=""
    case "$raw_arch" in
        x86_64|amd64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        *) log_err "Unsupported arch: $raw_arch"; return 1 ;;
    esac
    local tmp_file
    tmp_file="$(mktemp)"
    local url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$url" -o "$tmp_file"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$tmp_file" "$url"
    else
        rm -f "$tmp_file"
        log_err "Neither curl nor wget available"
        return 1
    fi
    chmod +x "$tmp_file"
    if [[ -w /usr/local/bin ]]; then
        install -m 0755 "$tmp_file" /usr/local/bin/cloudflared
        CLOUDFLARED_BIN="/usr/local/bin/cloudflared"
    else
        mkdir -p "$HOME/.local/bin"
        install -m 0755 "$tmp_file" "$HOME/.local/bin/cloudflared"
        CLOUDFLARED_BIN="$HOME/.local/bin/cloudflared"
    fi
    rm -f "$tmp_file"
    log "  ✓ cloudflared installed at $CLOUDFLARED_BIN"
}

relay_ssh() {
    local cmd="$1"
    local tout="${2:-30}"
    timeout "$tout" sshpass -p "$RELAY_PASS" ssh -o StrictHostKeyChecking=no \
        -o ConnectTimeout=10 -o ServerAliveInterval=5 \
        "$RELAY_HOST" "$cmd" 2>/dev/null || true
}

collect_scp() {
    local src="$1"
    local dest="$2"
    ensure_cloudflared || return 1
    local proxy_cmd="$CLOUDFLARED_BIN access ssh --hostname ssh.nitindermohan.com"
    sshpass -p "$COLLECT_PASS" scp -r \
        -o StrictHostKeyChecking=no \
        -o "ProxyCommand=$proxy_cmd" \
        "$src" "$COLLECT_HOST:$dest" 2>/dev/null
}

collect_ssh() {
    local cmd="$1"
    local tout="${2:-30}"
    ensure_cloudflared || return 1
    local proxy_cmd="$CLOUDFLARED_BIN access ssh --hostname ssh.nitindermohan.com"
    timeout "$tout" sshpass -p "$COLLECT_PASS" ssh \
        -o StrictHostKeyChecking=no \
        -o "ProxyCommand=$proxy_cmd" \
        "$COLLECT_HOST" "$cmd" 2>/dev/null || true
}

kill_echo_server() {
    # pkill -f would also match the sshd process, so use a pid file approach
    relay_ssh 'test -f /tmp/udp_echo.pid && kill $(cat /tmp/udp_echo.pid) 2>/dev/null; rm -f /tmp/udp_echo.pid; true'
}

cleanup_all() {
    log "  Cleaning up..."
    kill_echo_server
    docker rm -f net-measure 2>/dev/null || true
    sleep 1
}

check_connectivity() {
    log "Checking connectivity..."
    local ok=true

    # Check relay
    local relay_check
    relay_check=$(relay_ssh "echo relay_ok")
    if [[ "$relay_check" == *"relay_ok"* ]]; then
        log "  ✓ Relay reachable"
    else
        log_err "  ✗ Cannot reach relay ($RELAY_HOST)"
        ok=false
    fi

    # Check Docker image
    local host_arch
    host_arch=$(uname -m)
    local img_arch
    img_arch=$(docker inspect --format '{{.Architecture}}' "$SUB_IMAGE" 2>/dev/null || echo "none")
    local arch_match=false
    if [[ "$host_arch" == "x86_64" && "$img_arch" == "amd64" ]] || \
       [[ "$host_arch" == "aarch64" && "$img_arch" == "arm64" ]]; then
        arch_match=true
    fi
    if [[ "$arch_match" == true ]]; then
        log "  ✓ Docker image $SUB_IMAGE exists locally (arch: $img_arch)"
    else
        log "  Pulling Docker image $SUB_IMAGE ..."
        if docker pull "$SUB_IMAGE" >/dev/null 2>&1; then
            log "  ✓ Docker image $SUB_IMAGE pulled"
        elif docker image inspect "$SUB_IMAGE" >/dev/null 2>&1; then
            log "  ✓ Docker image $SUB_IMAGE exists (pull failed, using cached)"
        else
            log_err "  ✗ Docker image $SUB_IMAGE not found"
            ok=false
        fi
    fi

    # Check subscriber interface
    if ip link show "$SUB_INTERFACE" >/dev/null 2>&1; then
        log "  ✓ Interface $SUB_INTERFACE exists"
    else
        log_err "  ✗ Interface $SUB_INTERFACE not found"
        ok=false
    fi

    # Check collection host
    if [[ -n "${COLLECT_HOST:-}" ]]; then
        if ensure_cloudflared; then
            log "  ✓ cloudflared available: $CLOUDFLARED_BIN"
        else
            log_err "  ✗ cloudflared unavailable"
            ok=false
        fi
    fi

    if [[ "$ok" == false ]]; then
        log_err "Pre-flight checks failed."
        exit 1
    fi
    log "All pre-flight checks passed."
}

# ── Deploy echo server to relay ──────────────────────────────

deploy_echo_server() {
    log "  Deploying UDP echo server to relay..."
    # Upload the echo server script from subscriber to relay
    local rc=0
    sshpass -p "$RELAY_PASS" scp -o StrictHostKeyChecking=no \
        "$SCRIPT_DIR/relay/udp_echo_server.py" \
        "$RELAY_HOST:/tmp/udp_echo_server.py" 2>/dev/null || rc=$?

    if [[ $rc -ne 0 ]]; then
        log_err "  Failed to upload echo server (rc=$rc)"
        return 1
    fi
    log "  ✓ Echo server deployed to relay"
}

start_echo_server() {
    kill_echo_server
    sleep 1
    # Create a start script on the relay to avoid pkill/pgrep killing SSH
    relay_ssh 'cat > /tmp/start_echo.sh << "INNEREOF"
#!/bin/bash
nohup python3 /tmp/udp_echo_server.py --port '"$RELAY_ECHO_PORT"' > /tmp/udp_echo_server.log 2>&1 &
echo $! > /tmp/udp_echo.pid
echo $!
INNEREOF
chmod +x /tmp/start_echo.sh' 15

    local pid
    pid=$(relay_ssh '/tmp/start_echo.sh' 15)
    sleep 2

    # Verify it's running by checking the pid file
    local check
    check=$(relay_ssh 'test -f /tmp/udp_echo.pid && kill -0 $(cat /tmp/udp_echo.pid) 2>/dev/null && echo running || echo stopped')
    if [[ "$check" != *"running"* ]]; then
        log_err "  Echo server failed to start on relay"
        relay_ssh 'cat /tmp/udp_echo_server.log 2>/dev/null'
        return 1
    fi
    log "  ✓ Echo server running (pid: $pid)"
}

# ── Single measurement run ───────────────────────────────────

run_single() {
    local run_id="$1"
    local run_dir="$RESULT_DIR/run_$(printf '%03d' "$run_id")"
    mkdir -p "$run_dir"

    log "╔══════════════════════════════════════════════╗"
    log "║  Measurement Run $run_id / $END_RUN"
    log "║  Interface: $SUB_INTERFACE"
    log "║  Output: $run_dir"
    log "╚══════════════════════════════════════════════╝"

    local run_start
    run_start=$(date +%s)

    # Cleanup stale containers
    docker rm -f net-measure 2>/dev/null || true

    # Ensure echo server is running
    local check
    check=$(relay_ssh 'test -f /tmp/udp_echo.pid && kill -0 $(cat /tmp/udp_echo.pid) 2>/dev/null && echo running || echo stopped')
    if [[ "$check" != *"running"* ]]; then
        log "  Echo server not running, restarting..."
        start_echo_server || return 1
    fi

    local relay_ip="${RELAY_HOST##*@}"
    local abs_run_dir
    abs_run_dir="$(cd "$run_dir" && pwd)"

    # Run measurement container
    log "  [1/2] Running RTT measurement + traceroute..."
    docker run --name net-measure \
        --network host \
        --cap-add NET_RAW \
        -v "$abs_run_dir:/results" \
        "$SUB_IMAGE" \
        --relay-ip "$relay_ip" \
        --relay-port "$RELAY_ECHO_PORT" \
        --interface "$SUB_INTERFACE" \
        --duration "$RTT_DURATION" \
        --interval "$RTT_INTERVAL" \
        --traceroute-rounds "$TRACEROUTE_ROUNDS" \
        --output-dir /results

    local exit_code=$?
    docker rm -f net-measure 2>/dev/null || true

    # Validate results
    log "  [2/2] Validating results..."
    local status="OK"

    if [[ -f "$run_dir/rtt.csv" ]]; then
        local lines
        lines=$(wc -l < "$run_dir/rtt.csv")
        log "  ✓ rtt.csv: $((lines - 1)) data rows"
        if [[ $lines -le 1 ]]; then
            status="EMPTY_RTT"
        fi
    else
        log_err "  ✗ rtt.csv missing"
        status="MISSING_RTT"
    fi

    if [[ -f "$run_dir/traceroute.txt" ]]; then
        local tr_lines
        tr_lines=$(wc -l < "$run_dir/traceroute.txt")
        log "  ✓ traceroute.txt: $tr_lines lines"
    else
        log_err "  ✗ traceroute.txt missing"
        [[ "$status" == "OK" ]] && status="MISSING_TRACEROUTE"
    fi

    local run_end
    run_end=$(date +%s)
    local duration=$((run_end - run_start))

    echo "$status" > "$run_dir/STATUS"
    log "  Run $run_id complete: $status (${duration}s)"
    echo "$run_id,$status,$duration" >> "$RESULT_DIR/run_log.csv"

    # Forward to collection host
    if [[ -n "${COLLECT_HOST:-}" ]]; then
        local run_tag
        run_tag="run_$(printf '%03d' "$run_id")"
        log "  Forwarding $run_tag to collection host..."
        collect_ssh "mkdir -p $COLLECT_DIR" 15
        if collect_scp "$run_dir" "$COLLECT_DIR/"; then
            log "  ✓ Forwarded $run_tag"
        else
            log "  ✗ Warning: forward failed (data stays local)"
        fi
    fi

    return 0
}

# ── Main ─────────────────────────────────────────────────────

main() {
    log "╔══════════════════════════════════════════════════════╗"
    log "║  Single-Path Network Measurement                    ║"
    log "║  Runs: $START_RUN → $END_RUN  Interface: $SUB_INTERFACE"
    log "╚══════════════════════════════════════════════════════╝"

    mkdir -p "$RESULT_DIR"

    # Pre-flight
    check_connectivity

    if [[ "$DRY_RUN" == true ]]; then
        log "Dry run complete. All checks passed."
        exit 0
    fi

    # Deploy and start echo server
    deploy_echo_server
    start_echo_server || { log_err "Cannot start echo server"; exit 1; }

    # Initialize run log
    if [[ ! -f "$RESULT_DIR/run_log.csv" ]]; then
        echo "run_id,status,duration_s" > "$RESULT_DIR/run_log.csv"
    fi

    # Main loop
    local success=0
    local fail=0
    for run_id in $(seq "$START_RUN" "$END_RUN"); do
        if run_single "$run_id"; then
            success=$((success + 1))
        else
            fail=$((fail + 1))
        fi
        if [[ "$run_id" -lt "$END_RUN" ]]; then
            log "  Waiting ${INTER_RUN_GAP}s before next run..."
            sleep "$INTER_RUN_GAP"
        fi
    done

    # Final cleanup
    cleanup_all

    log ""
    log "════════════════════════════════════════════════"
    log "  MEASUREMENT COMPLETE"
    log "  Successful: $success / $((success + fail))"
    log "  Failed:     $fail / $((success + fail))"
    log "  Results:    $RESULT_DIR"
    log "════════════════════════════════════════════════"

    # Forward summary to collection host
    if [[ -n "${COLLECT_HOST:-}" ]]; then
        log "  Forwarding summary files..."
        collect_ssh "mkdir -p $COLLECT_DIR" 15
        collect_scp "$RESULT_DIR/run_log.csv" "$COLLECT_DIR/run_log.csv" || true
        log "  ✓ Summary forwarded"
    fi
}

main "$@" 2>&1 | tee -a "$SCRIPT_DIR/measurement.log"
