#!/usr/bin/env python3
"""
Traceroute runner.

Executes N rounds of traceroute to a target IP using a specified interface
and saves the combined output to a text file.

Usage:
  python3 traceroute_runner.py --target 5.75.186.96 --interface eth0 \
      --rounds 5 --output /results/traceroute.txt
"""

import argparse
import subprocess
import sys


def run_traceroute(target: str, interface: str, rounds: int, output: str):
    lines = []
    for i in range(1, rounds + 1):
        header = f"=== Traceroute round {i}/{rounds} ==="
        print(header, flush=True)
        lines.append(header)

        cmd = ["traceroute"]
        if interface:
            cmd += ["-i", interface]
        cmd.append(target)

        try:
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=60,
            )
            out = result.stdout.strip()
            err = result.stderr.strip()
            if out:
                print(out, flush=True)
                lines.append(out)
            if err:
                print(f"(stderr) {err}", flush=True)
                lines.append(f"(stderr) {err}")
        except subprocess.TimeoutExpired:
            msg = f"Round {i} timed out after 60s"
            print(msg, flush=True)
            lines.append(msg)
        except FileNotFoundError:
            msg = "traceroute command not found"
            print(msg, flush=True)
            lines.append(msg)
            break

        lines.append("")

    with open(output, "w") as f:
        f.write("\n".join(lines) + "\n")

    print(f"Saved {rounds} rounds to {output}", flush=True)


def main():
    parser = argparse.ArgumentParser(description="Traceroute Runner")
    parser.add_argument("--target", required=True, help="Target IP")
    parser.add_argument("--interface", type=str, default="", help="Network interface")
    parser.add_argument("--rounds", type=int, default=5, help="Number of rounds")
    parser.add_argument("--output", type=str, default="/results/traceroute.txt", help="Output file")
    args = parser.parse_args()

    run_traceroute(args.target, args.interface, args.rounds, args.output)


if __name__ == "__main__":
    main()
