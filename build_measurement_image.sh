#!/usr/bin/env bash
# ============================================================
# build_measurement_image.sh — Build and optionally push the
# single-path network measurement Docker image.
#
# Usage:
#   ./build_measurement_image.sh              # build only
#   ./build_measurement_image.sh --push       # build and push to GHCR
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

IMAGE_NAME="ghcr.io/120l021101/canada_experiment_single_path/measurement:latest"
PUSH=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --push) PUSH=true; shift ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

echo "Building measurement Docker image..."
echo "  Image: $IMAGE_NAME"

docker build -f Dockerfile.measurement -t "$IMAGE_NAME" .

echo ""
echo "✓ Image built: $IMAGE_NAME"
docker images "$IMAGE_NAME"

if [[ "$PUSH" == true ]]; then
    echo ""
    echo "Pushing to GHCR..."
    docker push "$IMAGE_NAME"
    echo "✓ Pushed: $IMAGE_NAME"
fi
