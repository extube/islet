#!/usr/bin/env bash
set -Eeuo pipefail

IMAGE="ghcr.io/anomalyco/opencode:latest"
CONFIG_DIR="${HOME}/.config/opencode"

# Use the supplied path, or the current directory if no path is provided.
WORKSPACE="${1:-$PWD}"

# Convert to an absolute path and verify it exists.
if [[ ! -d "$WORKSPACE" ]]; then
  echo "Error: workspace directory does not exist: $WORKSPACE" >&2
  exit 1
fi

WORKSPACE="$(cd "$WORKSPACE" && pwd)"
mkdir -p "$CONFIG_DIR"

echo "Workspace: $WORKSPACE"

exec docker run --rm -it \
  --name opencode \
  --network host \
  --workdir /workspace \
  --volume "$WORKSPACE:/workspace" \
  --volume "$CONFIG_DIR:/root/.config/opencode" \
  "$IMAGE"
