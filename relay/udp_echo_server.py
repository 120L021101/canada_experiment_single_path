#!/usr/bin/env python3
"""
UDP Echo Server for RTT measurement.
Listens on a specified port and echoes back every received packet unchanged.
Runs as a bare process on the relay machine.
"""

import argparse
import socket
import signal
import sys


def main():
    parser = argparse.ArgumentParser(description="UDP Echo Server")
    parser.add_argument("--port", type=int, default=5201, help="UDP port to listen on (default: 5201)")
    parser.add_argument("--bind", type=str, default="0.0.0.0", help="Bind address (default: 0.0.0.0)")
    args = parser.parse_args()

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind((args.bind, args.port))

    print(f"UDP Echo Server listening on {args.bind}:{args.port}", flush=True)

    pkt_count = 0

    def shutdown(signum, frame):
        print(f"\nShutting down. Echoed {pkt_count} packets.", flush=True)
        sock.close()
        sys.exit(0)

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    while True:
        try:
            data, addr = sock.recvfrom(4096)
            sock.sendto(data, addr)
            pkt_count += 1
        except OSError:
            break


if __name__ == "__main__":
    main()
