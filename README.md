# Single-Path Network Measurement

UDP RTT measurement and traceroute from subscriber (Finland) to relay (Germany) over a single network interface.

## Components

- **Relay** (`relay/udp_echo_server.py`): Bare Python UDP echo server, deployed to the relay machine.
- **Subscriber** (`subscriber/`): Python measurement client (RTT probing + traceroute), packaged as a Docker container.

## Quick Start

```bash
# 1. Build measurement Docker image (on subscriber machine)
./build_measurement_image.sh

# 2. Run 3 measurement runs
./run_measurement.sh

# Override interface:
./run_measurement.sh --interface eth0

# Dry run (check connectivity only):
./run_measurement.sh --dry-run
```

## Configuration

Edit `experiment.env` to change hosts, ports, measurement parameters.

## Output

Each run produces:
- `rtt.csv`: Columns `timestamp, RTT_measured` (ms). `-1` / `NaN` for lost probes.
- `traceroute.txt`: 5 rounds of traceroute output.
- `STATUS`: `OK` or error code.
