#!/usr/bin/env bash
# ============================================================
# run_measurement.sh — Single-path experiment driver
#
# Runs on the SUBSCRIBER machine (Finland).
# Per run:
#   Phase 1: Network measurement (UDP RTT + traceroute)
#   Phase 2: MoQ video streaming (publisher → relay → subscriber)
# All results forwarded to collection host via cloudflared.
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

pub_ssh() {
    local cmd="$1"
    local tout="${2:-30}"
    timeout "$tout" sshpass -p "$PUB_PASS" ssh -o StrictHostKeyChecking=no \
        -o ConnectTimeout=10 -o ServerAliveInterval=5 \
        -p "$PUB_PORT" "$PUB_HOST" "$cmd" 2>/dev/null || true
}

collect_scp() {
    local src="$1"
    local dest="$2"
    ensure_cloudflared || return 1
    local proxy_cmd="$CLOUDFLARED_BIN access ssh --hostname ssh.nitindermohan.com"
    local rc=0
    sshpass -p "$COLLECT_PASS" scp -r \
        -o StrictHostKeyChecking=no \
        -o "ProxyCommand=$proxy_cmd" \
        "$src" "$COLLECT_HOST:$dest" || rc=$?
    if [[ $rc -ne 0 ]]; then
        log_err "  SCP to collection host failed (rc=$rc)"
        return 1
    fi
    return 0
}

collect_ssh() {
    local cmd="$1"
    local tout="${2:-30}"
    ensure_cloudflared || return 1
    local proxy_cmd="$CLOUDFLARED_BIN access ssh --hostname ssh.nitindermohan.com"
    timeout "$tout" sshpass -p "$COLLECT_PASS" ssh \
        -o StrictHostKeyChecking=no \
        -o "ProxyCommand=$proxy_cmd" \
        "$COLLECT_HOST" "$cmd" || true
}

check_docker_image() {
    local image="$1"
    local host_arch
    host_arch=$(uname -m)
    local img_arch
    img_arch=$(docker inspect --format '{{.Architecture}}' "$image" 2>/dev/null || echo "none")
    local arch_match=false
    if [[ "$host_arch" == "x86_64" && "$img_arch" == "amd64" ]] || \
       [[ "$host_arch" == "aarch64" && "$img_arch" == "arm64" ]]; then
        arch_match=true
    fi
    if [[ "$arch_match" == true ]]; then
        log "  ✓ Docker image $image (arch: $img_arch)"
        return 0
    fi
    log "  Pulling Docker image $image ..."
    if docker pull "$image" >/dev/null 2>&1; then
        log "  ✓ Docker image $image pulled"
        return 0
    elif docker image inspect "$image" >/dev/null 2>&1; then
        log "  ✓ Docker image $image (cached)"
        return 0
    fi
    log_err "  ✗ Docker image $image not found"
    return 1
}

# ── Echo server lifecycle (Phase 1) ─────────────────────────

deploy_echo_server() {
    log "  Deploying UDP echo server to relay..."
    local rc=0
    sshpass -p "$RELAY_PASS" scp -o StrictHostKeyChecking=no \
        "$SCRIPT_DIR/relay/udp_echo_server.py" \
        "$RELAY_HOST:/tmp/udp_echo_server.py" 2>/dev/null || rc=$?
    if [[ $rc -ne 0 ]]; then
        log_err "  Failed to upload echo server (rc=$rc)"
        return 1
    fi
    log "  ✓ Echo server deployed"
}

kill_echo_server() {
    relay_ssh 'test -f /tmp/udp_echo.pid && kill $(cat /tmp/udp_echo.pid) 2>/dev/null; rm -f /tmp/udp_echo.pid; true'
}

start_echo_server() {
    kill_echo_server
    sleep 1
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
    local check
    check=$(relay_ssh 'test -f /tmp/udp_echo.pid && kill -0 $(cat /tmp/udp_echo.pid) 2>/dev/null && echo running || echo stopped')
    if [[ "$check" != *"running"* ]]; then
        log_err "  Echo server failed to start"
        relay_ssh 'cat /tmp/udp_echo_server.log 2>/dev/null'
        return 1
    fi
    log "  ✓ Echo server running (pid: $pid)"
}

# ── MoQ config deployment (Phase 2) ─────────────────────────

deploy_moq_configs() {
    log "  Deploying MoQ configs..."
    # Upload relay config
    local rc=0
    sshpass -p "$RELAY_PASS" scp -o StrictHostKeyChecking=no \
        "$SCRIPT_DIR/config/relay_config.yaml" \
        "$RELAY_HOST:/tmp/sp_relay_config.yaml" 2>/dev/null || rc=$?
    if [[ $rc -ne 0 ]]; then
        log_err "  Failed to upload relay config"
        return 1
    fi
    # Upload publisher config
    rc=0
    sshpass -p "$PUB_PASS" scp -o StrictHostKeyChecking=no -P "$PUB_PORT" \
        "$SCRIPT_DIR/config/publisher_config.yaml" \
        "$PUB_HOST:/tmp/sp_publisher_config.yaml" 2>/dev/null || rc=$?
    if [[ $rc -ne 0 ]]; then
        log_err "  Failed to upload publisher config"
        return 1
    fi
    log "  ✓ MoQ configs deployed"
}

generate_subscriber_config() {
    local config_out="$RESULT_DIR/_active_subscriber_config.yaml"
    local relay_ip="${RELAY_HOST##*@}"
    cat > "$config_out" <<EOF
max_idle_timeout: 30000
enable_multipath: false
active_connection_id_limit: 8
initial_max_streams_uni: 10000
initial_max_streams_bidi: 100
initial_max_data: 50000000
initial_max_stream_data_bidi_local: 100000
initial_max_stream_data_bidi_remote: 100000
initial_max_stream_data_uni: 5000000
multipath_algorithm: "minrtt"
frames_per_gop: 50
multipath_paths: ["${SUB_INTERFACE}"]
multipath_local_addresses:
  - "0.0.0.0:0"
multipath_remote_addresses:
  - "${relay_ip}:${RELAY_MOQ_PORT}"
EOF
    echo "$config_out"
}

# ── Cleanup ──────────────────────────────────────────────────

cleanup_all() {
    log "  Cleaning up all machines..."
    kill_echo_server
    relay_ssh 'pkill -f tquic_moq_relay 2>/dev/null; pkill -f "tcpdump.*4443" 2>/dev/null; true'
    pub_ssh 'pkill -f tquic_moq_publisher 2>/dev/null; pkill -f "tcpdump.*4443" 2>/dev/null; true'
    docker rm -f net-measure 2>/dev/null || true
    docker rm -f moq-sub 2>/dev/null || true
    sleep 2
}

# ── Pre-flight checks ───────────────────────────────────────

check_connectivity() {
    log "Checking connectivity..."
    local ok=true

    # Relay
    local relay_check
    relay_check=$(relay_ssh "echo relay_ok")
    if [[ "$relay_check" == *"relay_ok"* ]]; then
        log "  ✓ Relay reachable"
    else
        log_err "  ✗ Cannot reach relay ($RELAY_HOST)"
        ok=false
    fi

    # Publisher
    local pub_check
    pub_check=$(pub_ssh "echo pub_ok")
    if [[ "$pub_check" == *"pub_ok"* ]]; then
        log "  ✓ Publisher reachable"
    else
        log_err "  ✗ Cannot reach publisher ($PUB_HOST:$PUB_PORT)"
        ok=false
    fi

    # Interface
    if ip link show "$SUB_INTERFACE" >/dev/null 2>&1; then
        log "  ✓ Interface $SUB_INTERFACE exists"
    else
        log_err "  ✗ Interface $SUB_INTERFACE not found"
        ok=false
    fi

    # Docker images
    check_docker_image "$MEASURE_IMAGE" || ok=false
    check_docker_image "$MOQ_SUB_IMAGE" || ok=false

    # Relay binary
    local relay_bin_check
    relay_bin_check=$(relay_ssh "test -x $RELAY_REPO/$RELAY_BINARY && echo bin_ok")
    if [[ "$relay_bin_check" == *"bin_ok"* ]]; then
        log "  ✓ Relay binary exists"
    else
        log_err "  ✗ Relay binary not found at $RELAY_REPO/$RELAY_BINARY"
        ok=false
    fi

    # Publisher binary + video
    local pub_bin_check
    pub_bin_check=$(pub_ssh "test -x $PUB_REPO/$PUB_BINARY && test -f $PUB_VIDEO && echo bin_ok")
    if [[ "$pub_bin_check" == *"bin_ok"* ]]; then
        log "  ✓ Publisher binary + video exist"
    else
        log_err "  ✗ Publisher binary or video missing"
        ok=false
    fi

    # Cloudflared
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

# ── Single run ───────────────────────────────────────────────

run_single() {
    local run_id="$1"
    local run_dir="$RESULT_DIR/run_$(printf '%03d' "$run_id")"
    local run_tag="run_$(printf '%03d' "$run_id")"
    mkdir -p "$run_dir"

    log "╔══════════════════════════════════════════════╗"
    log "║  Run $run_id / $END_RUN"
    log "║  Interface: $SUB_INTERFACE"
    log "║  Output: $run_dir"
    log "╚══════════════════════════════════════════════╝"

    local run_start
    run_start=$(date +%s)

    # Cleanup stale processes from previous run
    cleanup_all

    local relay_ip="${RELAY_HOST##*@}"
    local abs_run_dir
    abs_run_dir="$(cd "$run_dir" && pwd)"

    # ══════════════════════════════════════════════════════════
    # Phase 1: Network Measurement (RTT + traceroute)
    # ══════════════════════════════════════════════════════════
    log "  ═══ Phase 1: Network Measurement ═══"

    # Ensure echo server is running
    local echo_check
    echo_check=$(relay_ssh 'test -f /tmp/udp_echo.pid && kill -0 $(cat /tmp/udp_echo.pid) 2>/dev/null && echo running || echo stopped')
    if [[ "$echo_check" != *"running"* ]]; then
        log "  Echo server not running, starting..."
        start_echo_server || {
            log_err "  Echo server failed, skipping measurement phase"
        }
    fi

    # Run measurement Docker container
    log "  [1/9] Running RTT + traceroute..."
    docker rm -f net-measure 2>/dev/null || true
    docker run --name net-measure \
        --network host \
        --cap-add NET_RAW \
        -v "$abs_run_dir:/results" \
        "$MEASURE_IMAGE" \
        --relay-ip "$relay_ip" \
        --relay-port "$RELAY_ECHO_PORT" \
        --interface "$SUB_INTERFACE" \
        --duration "$RTT_DURATION" \
        --interval "$RTT_INTERVAL" \
        --traceroute-rounds "$TRACEROUTE_ROUNDS" \
        --output-dir /results
    docker rm -f net-measure 2>/dev/null || true

    # Validate measurement
    if [[ -f "$run_dir/rtt.csv" ]]; then
        local rtt_lines
        rtt_lines=$(wc -l < "$run_dir/rtt.csv")
        log "  ✓ rtt.csv: $((rtt_lines - 1)) data rows"
    else
        log_err "  ✗ rtt.csv missing"
    fi
    if [[ -f "$run_dir/traceroute.txt" ]]; then
        local tr_lines
        tr_lines=$(wc -l < "$run_dir/traceroute.txt")
        log "  ✓ traceroute.txt: $tr_lines lines"
    else
        log_err "  ✗ traceroute.txt missing"
    fi

    # Stop echo server before MoQ phase
    kill_echo_server

    # ══════════════════════════════════════════════════════════
    # Phase 2: MoQ Video Streaming
    # ══════════════════════════════════════════════════════════
    log "  ═══ Phase 2: MoQ Video Streaming ═══"

    # Cleanup stale MoQ processes
    relay_ssh 'pkill -f tquic_moq_relay 2>/dev/null; pkill -f "tcpdump.*4443" 2>/dev/null; true'
    pub_ssh 'pkill -f tquic_moq_publisher 2>/dev/null; pkill -f "tcpdump.*4443" 2>/dev/null; true'
    docker rm -f moq-sub 2>/dev/null || true
    sleep 2

    local relay_result_dir="/tmp/sp_moq_results"
    local pub_result_dir="/tmp/sp_moq_pub_results"

    # [2/9] Start relay
    log "  [2/9] Starting MoQ relay..."
    relay_ssh "mkdir -p $relay_result_dir; \
        nohup tcpdump -i $RELAY_INTERFACE -w $relay_result_dir/relay_capture.pcap udp port $RELAY_MOQ_PORT > /dev/null 2>&1 </dev/null & \
        sleep 1; \
        nohup $RELAY_REPO/$RELAY_BINARY --quic-config=/tmp/sp_relay_config.yaml \
            --monitoring-out=$relay_result_dir/relay_monitoring.csv \
            > $relay_result_dir/relay.log 2>&1 </dev/null & \
        sleep 2; echo relay_started; exit 0" 15

    sleep 3
    local relay_pid
    relay_pid=$(relay_ssh "pgrep -f tquic_moq_relay || echo ''")
    if [[ -z "$relay_pid" ]]; then
        log_err "  MoQ relay failed to start. Checking log..."
        relay_ssh "cat $relay_result_dir/relay.log 2>/dev/null" 10
        echo "RELAY_START_FAILED" > "$run_dir/STATUS"
        echo "$run_id,RELAY_START_FAILED,0" >> "$RESULT_DIR/run_log.csv"
        cleanup_all
        return 1
    fi
    log "  ✓ MoQ relay started (pid: $relay_pid)"

    # [3/9] Start subscriber
    log "  [3/9] Starting MoQ subscriber (Docker)..."
    local sub_config
    sub_config=$(generate_subscriber_config)
    local abs_config
    abs_config="$(cd "$(dirname "$sub_config")" && pwd)/$(basename "$sub_config")"

    docker run -d --name moq-sub \
        --network host \
        -v "$abs_config:/config/subscriber_config.yaml:ro" \
        -v "$abs_run_dir:/results" \
        "$MOQ_SUB_IMAGE" \
        --quic-config=/config/subscriber_config.yaml \
        $SVC_ENABLED \
        --video-out=/results/received.264 \
        --monitoring-out=/results/frames_monitoring.csv \
        --frames-out=/results/frames \
        > /dev/null 2>&1

    sleep 5
    if ! docker ps --format '{{.Names}}' | grep -q moq-sub; then
        log_err "  MoQ subscriber container not running. Logs:"
        docker logs moq-sub 2>&1 | tail -10
        echo "SUBSCRIBER_START_FAILED" > "$run_dir/STATUS"
        echo "$run_id,SUBSCRIBER_START_FAILED,0" >> "$RESULT_DIR/run_log.csv"
        cleanup_all
        return 1
    fi
    log "  ✓ MoQ subscriber running"

    # [4/9] Start subscriber-side tcpdump (best-effort)
    log "  [4/9] Starting subscriber tcpdump..."
    local sub_tcpdump_pid=""
    if tcpdump -i any -w "$abs_run_dir/subscriber_capture.pcap" udp port "$RELAY_MOQ_PORT" > /dev/null 2>&1 & then
        sub_tcpdump_pid=$!
        log "  ✓ Subscriber tcpdump (pid: $sub_tcpdump_pid)"
    else
        log "  Warning: tcpdump failed, skipping subscriber pcap"
    fi
    sleep 1

    # [5/9] Start publisher
    log "  [5/9] Starting MoQ publisher..."
    pub_ssh "mkdir -p $pub_result_dir; cd $PUB_REPO; \
        nohup tcpdump -i $PUB_INTERFACE -w $pub_result_dir/publisher_capture.pcap udp port $RELAY_MOQ_PORT > /dev/null 2>&1 </dev/null & \
        sleep 1; \
        ENABLE_RATE_CONTROL=1 RUST_LOG=info \
        nohup $PUB_REPO/$PUB_BINARY \
            --quic-config=/tmp/sp_publisher_config.yaml \
            $PUB_VIDEO --svc --loop $PUB_LOOP_COUNT \
            > $pub_result_dir/publisher.log 2>&1 </dev/null & \
        sleep 1; echo pub_started; exit 0" 15
    sleep 2

    local pub_pid
    pub_pid=$(pub_ssh "pgrep -f tquic_moq_publisher || echo ''")
    if [[ -z "$pub_pid" ]]; then
        log_err "  MoQ publisher failed to start"
        echo "PUBLISHER_START_FAILED" > "$run_dir/STATUS"
        echo "$run_id,PUBLISHER_START_FAILED,0" >> "$RESULT_DIR/run_log.csv"
        cleanup_all
        return 1
    fi
    log "  ✓ MoQ publisher started (pid: $pub_pid)"

    # [6/9] Wait for publisher
    log "  [6/9] Waiting for publisher (timeout ${PUBLISHER_TIMEOUT}s)..."
    local wait_start
    wait_start=$(date +%s)
    while true; do
        local elapsed=$(( $(date +%s) - wait_start ))
        if [[ $elapsed -ge $PUBLISHER_TIMEOUT ]]; then
            log "  Publisher timed out after ${PUBLISHER_TIMEOUT}s, killing..."
            pub_ssh "pkill -f tquic_moq_publisher 2>/dev/null; true"
            break
        fi
        local still_running
        still_running=$(pub_ssh "pgrep -f tquic_moq_publisher || echo ''")
        if [[ -z "$still_running" ]]; then
            log "  Publisher finished after ~${elapsed}s"
            break
        fi
        sleep 10
    done

    # [7/9] Grace period
    log "  [7/9] Grace period (${SUBSCRIBER_GRACE}s)..."
    sleep "$SUBSCRIBER_GRACE"

    # [8/9] Collect MoQ results
    log "  [8/9] Collecting MoQ results..."

    # Save subscriber Docker logs
    docker logs moq-sub > "$run_dir/subscriber.log" 2>&1 || true
    docker stop moq-sub --timeout 5 2>/dev/null || true
    docker rm -f moq-sub 2>/dev/null || true

    # Stop subscriber tcpdump
    if [[ -n "${sub_tcpdump_pid:-}" ]]; then
        kill "$sub_tcpdump_pid" 2>/dev/null || true
    fi

    # Stop relay + collect relay results
    relay_ssh "pkill -f tquic_moq_relay 2>/dev/null; pkill -f 'tcpdump.*$RELAY_MOQ_PORT' 2>/dev/null; true"
    sleep 2

    # Fetch relay log
    local relay_log
    relay_log=$(relay_ssh "cat $relay_result_dir/relay.log 2>/dev/null")
    echo "$relay_log" > "$run_dir/relay.log"

    # Fetch relay monitoring CSV
    local relay_csv
    relay_csv=$(relay_ssh "cat $relay_result_dir/relay_monitoring.csv 2>/dev/null")
    [[ -n "$relay_csv" ]] && echo "$relay_csv" > "$run_dir/relay_monitoring.csv"

    # Fetch relay pcap
    local rc=0
    sshpass -p "$RELAY_PASS" scp -o StrictHostKeyChecking=no \
        "$RELAY_HOST:$relay_result_dir/relay_capture.pcap" \
        "$run_dir/relay_capture.pcap" 2>/dev/null || rc=$?
    [[ $rc -ne 0 ]] && log "  Warning: failed to fetch relay pcap"

    # Stop publisher + collect publisher results
    pub_ssh "pkill -f tquic_moq_publisher 2>/dev/null; pkill -f 'tcpdump.*$RELAY_MOQ_PORT' 2>/dev/null; true"
    sleep 2

    # Fetch publisher log
    local pub_log
    pub_log=$(pub_ssh "cat $pub_result_dir/publisher.log 2>/dev/null")
    echo "$pub_log" > "$run_dir/publisher.log"

    # Fetch publisher pcap
    rc=0
    sshpass -p "$PUB_PASS" scp -o StrictHostKeyChecking=no -P "$PUB_PORT" \
        "$PUB_HOST:$pub_result_dir/publisher_capture.pcap" \
        "$run_dir/publisher_capture.pcap" 2>/dev/null || rc=$?
    [[ $rc -ne 0 ]] && log "  Warning: failed to fetch publisher pcap"

    # Cleanup remote temp dirs
    relay_ssh "rm -rf $relay_result_dir"
    pub_ssh "rm -rf $pub_result_dir"

    # [9/9] Validate all results
    log "  [9/9] Validating results..."
    local status="OK"

    # Check measurement files
    [[ ! -f "$run_dir/rtt.csv" ]] && { log_err "  ✗ rtt.csv missing"; [[ "$status" == "OK" ]] && status="MISSING_RTT"; }
    [[ ! -f "$run_dir/traceroute.txt" ]] && { log_err "  ✗ traceroute.txt missing"; [[ "$status" == "OK" ]] && status="MISSING_TRACEROUTE"; }

    # Check MoQ files
    if [[ -f "$run_dir/frames_monitoring.csv" ]]; then
        local fm_lines
        fm_lines=$(wc -l < "$run_dir/frames_monitoring.csv")
        log "  ✓ frames_monitoring.csv: $fm_lines lines"
    else
        log_err "  ✗ frames_monitoring.csv missing"
        [[ "$status" == "OK" ]] && status="MISSING_FRAMES_CSV"
    fi

    if [[ -f "$run_dir/received.264" ]]; then
        local vsize
        vsize=$(stat -c%s "$run_dir/received.264" 2>/dev/null || echo 0)
        log "  ✓ received.264: $(( vsize / 1024 ))KB"
    else
        log_err "  ✗ received.264 missing"
        [[ "$status" == "OK" ]] && status="MISSING_VIDEO"
    fi

    local run_end
    run_end=$(date +%s)
    local duration=$((run_end - run_start))

    echo "$status" > "$run_dir/STATUS"
    log "  Run $run_id complete: $status (${duration}s)"
    echo "$run_id,$status,$duration" >> "$RESULT_DIR/run_log.csv"

    # ── Forward to collection host ────────────────────────────
    if [[ -n "${COLLECT_HOST:-}" ]]; then
        log "  Forwarding $run_tag to collection host..."
        collect_ssh "mkdir -p $COLLECT_DIR" 15
        if collect_scp "$run_dir" "$COLLECT_DIR/"; then
            log "  ✓ Forwarded $run_tag"
        else
            log_err "  ✗ Forward failed (data preserved locally at $run_dir)"
        fi
    fi

    return 0
}

# ── Main ─────────────────────────────────────────────────────

main() {
    log "╔══════════════════════════════════════════════════════╗"
    log "║  Single-Path Experiment                             ║"
    log "║  Phase 1: Network Measurement (RTT + traceroute)    ║"
    log "║  Phase 2: MoQ Video Streaming                       ║"
    log "║  Runs: $START_RUN → $END_RUN  Interface: $SUB_INTERFACE"
    log "╚══════════════════════════════════════════════════════╝"

    mkdir -p "$RESULT_DIR"

    # Pre-flight
    check_connectivity

    if [[ "$DRY_RUN" == true ]]; then
        log "Dry run complete. All checks passed."
        exit 0
    fi

    # Deploy echo server + MoQ configs
    deploy_echo_server
    deploy_moq_configs
    start_echo_server || { log_err "Cannot start echo server"; exit 1; }

    # Generate subscriber config
    generate_subscriber_config > /dev/null

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
    log "  EXPERIMENT COMPLETE"
    log "  Successful: $success / $((success + fail))"
    log "  Failed:     $fail / $((success + fail))"
    log "  Results:    $RESULT_DIR"
    log "════════════════════════════════════════════════"

    # Forward summary to collection host
    if [[ -n "${COLLECT_HOST:-}" ]]; then
        log "  Forwarding summary files to collection host..."
        collect_ssh "mkdir -p $COLLECT_DIR" 15
        collect_scp "$RESULT_DIR/run_log.csv" "$COLLECT_DIR/run_log.csv" || true
        [[ -f "$SCRIPT_DIR/measurement.log" ]] && \
            collect_scp "$SCRIPT_DIR/measurement.log" "$COLLECT_DIR/measurement.log" || true
        log "  ✓ Summary forwarded"
    fi
}

main "$@" 2>&1 | tee -a "$SCRIPT_DIR/measurement.log"
