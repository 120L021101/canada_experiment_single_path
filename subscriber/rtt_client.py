#!/usr/bin/env python3
"""
UDP RTT Measurement Client.

Sends UDP probe packets at a fixed interval to the relay echo server and
measures the round-trip time for each.  Results are saved to a CSV file.

Each probe packet layout (32 bytes):
  [4B seq_id big-endian uint32][8B send_timestamp_ns big-endian uint64][20B padding]

Usage:
  python3 rtt_client.py --relay-ip 5.75.186.96 --relay-port 5201 \
      --interface eth0 --duration 60 --interval 10 --output /results/rtt.csv
"""

import argparse
import csv
import os
import socket
import struct
import time
import signal
import sys


PACKET_FMT = "!IQ"          # seq_id (4B) + timestamp_ns (8B) = 12B header
HEADER_SIZE = struct.calcsize(PACKET_FMT)
PACKET_SIZE = 32             # total payload including zero-padding
RECV_TIMEOUT = 2.0           # seconds to wait for echo reply


def bind_to_interface(sock, interface: str):
    """Bind the socket to a specific network interface via SO_BINDTODEVICE."""
    try:
        sock.setsockopt(
            socket.SOL_SOCKET,
            socket.SO_BINDTODEVICE,
            interface.encode() + b"\0",
        )
    except PermissionError:
        print(f"WARNING: SO_BINDTODEVICE requires CAP_NET_RAW / root. "
              f"Falling back to default routing for interface '{interface}'.",
              flush=True)


def run_measurement(relay_ip: str, relay_port: int, interface: str,
                    duration: float, interval_ms: float, output: str):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(RECV_TIMEOUT)

    if interface:
        bind_to_interface(sock, interface)

    results = []
    seq = 0
    stop = False

    def on_signal(signum, frame):
        nonlocal stop
        stop = True

    signal.signal(signal.SIGTERM, on_signal)
    signal.signal(signal.SIGINT, on_signal)

    interval_s = interval_ms / 1000.0
    end_time = time.time() + duration
    print(f"Starting RTT measurement: relay={relay_ip}:{relay_port} "
          f"iface={interface} duration={duration}s interval={interval_ms}ms",
          flush=True)

    while time.time() < end_time and not stop:
        send_ts_ns = time.time_ns()
        send_ts_s = send_ts_ns / 1e9
        payload = struct.pack(PACKET_FMT, seq, send_ts_ns)
        payload += b"\x00" * (PACKET_SIZE - HEADER_SIZE)

        try:
            sock.sendto(payload, (relay_ip, relay_port))
        except OSError as e:
            print(f"  send error seq={seq}: {e}", flush=True)
            seq += 1
            time.sleep(interval_s)
            continue

        try:
            data, _ = sock.recvfrom(4096)
            recv_ts_ns = time.time_ns()
            if len(data) >= HEADER_SIZE:
                echo_seq, echo_ts = struct.unpack(PACKET_FMT, data[:HEADER_SIZE])
                if echo_seq == seq and echo_ts == send_ts_ns:
                    rtt_ms = (recv_ts_ns - send_ts_ns) / 1e6
                    results.append((send_ts_s, rtt_ms))
                else:
                    # Stale / mismatched echo — treat as lost
                    results.append((send_ts_s, -1))
        except socket.timeout:
            results.append((send_ts_s, -1))
        except OSError:
            results.append((send_ts_s, -1))

        seq += 1

        # Pace the next send
        elapsed = (time.time_ns() - send_ts_ns) / 1e9
        sleep_for = interval_s - elapsed
        if sleep_for > 0:
            time.sleep(sleep_for)

    sock.close()

    # ── Write CSV ────────────────────────────────────────────
    os.makedirs(os.path.dirname(output) if os.path.dirname(output) else ".", exist_ok=True)
    with open(output, "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["timestamp", "RTT_measured"])
        for ts, rtt in results:
            writer.writerow([f"{ts:.6f}", f"{rtt:.3f}" if rtt >= 0 else "NaN"])

    lost = sum(1 for _, r in results if r < 0)
    valid = [r for _, r in results if r >= 0]
    print(f"Done. Sent {seq} probes, received {len(valid)}, lost {lost}.", flush=True)
    if valid:
        avg = sum(valid) / len(valid)
        mn, mx = min(valid), max(valid)
        valid_sorted = sorted(valid)
        p50 = valid_sorted[len(valid_sorted) // 2]
        p99_idx = min(int(len(valid_sorted) * 0.99), len(valid_sorted) - 1)
        p99 = valid_sorted[p99_idx]
        print(f"  RTT stats: min={mn:.2f}ms  median={p50:.2f}ms  "
              f"mean={avg:.2f}ms  p99={p99:.2f}ms  max={mx:.2f}ms", flush=True)
    print(f"  Saved to {output}", flush=True)


def main():
    parser = argparse.ArgumentParser(description="UDP RTT Measurement Client")
    parser.add_argument("--relay-ip", required=True, help="Relay server IP")
    parser.add_argument("--relay-port", type=int, default=5201, help="Relay UDP port")
    parser.add_argument("--interface", type=str, default="", help="Network interface to bind to")
    parser.add_argument("--duration", type=float, default=60, help="Measurement duration in seconds")
    parser.add_argument("--interval", type=float, default=10, help="Probe interval in milliseconds")
    parser.add_argument("--output", type=str, default="/results/rtt.csv", help="Output CSV path")
    args = parser.parse_args()

    run_measurement(args.relay_ip, args.relay_port, args.interface,
                    args.duration, args.interval, args.output)


if __name__ == "__main__":
    main()
