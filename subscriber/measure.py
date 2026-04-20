#!/usr/bin/env python3
"""
Measurement entry point — runs RTT measurement then traceroute.
This is the Docker container's ENTRYPOINT.
"""

import argparse
import importlib
import sys
import os

# Add the script directory to path so we can import siblings
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import rtt_client
import traceroute_runner


def main():
    parser = argparse.ArgumentParser(description="Network Measurement Suite")
    parser.add_argument("--relay-ip", required=True, help="Relay server IP")
    parser.add_argument("--relay-port", type=int, default=5201, help="Relay UDP port")
    parser.add_argument("--interface", type=str, default="", help="Network interface to bind/use")
    parser.add_argument("--duration", type=float, default=60, help="RTT measurement duration (seconds)")
    parser.add_argument("--interval", type=float, default=10, help="Probe interval (milliseconds)")
    parser.add_argument("--traceroute-rounds", type=int, default=5, help="Traceroute rounds")
    parser.add_argument("--output-dir", type=str, default="/results", help="Output directory")
    args = parser.parse_args()

    os.makedirs(args.output_dir, exist_ok=True)

    rtt_csv = os.path.join(args.output_dir, "rtt.csv")
    trace_txt = os.path.join(args.output_dir, "traceroute.txt")

    # Step 1: RTT measurement
    print("=" * 60, flush=True)
    print("  Phase 1: UDP RTT Measurement", flush=True)
    print("=" * 60, flush=True)
    rtt_client.run_measurement(
        relay_ip=args.relay_ip,
        relay_port=args.relay_port,
        interface=args.interface,
        duration=args.duration,
        interval_ms=args.interval,
        output=rtt_csv,
    )

    # Step 2: Traceroute
    print("", flush=True)
    print("=" * 60, flush=True)
    print("  Phase 2: Traceroute", flush=True)
    print("=" * 60, flush=True)
    traceroute_runner.run_traceroute(
        target=args.relay_ip,
        interface=args.interface,
        rounds=args.traceroute_rounds,
        output=trace_txt,
    )

    print("", flush=True)
    print("All measurements complete.", flush=True)


if __name__ == "__main__":
    main()
