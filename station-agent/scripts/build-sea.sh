#!/usr/bin/env bash
set -euo pipefail

ARCH="${1:-arm64}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT="$AGENT_DIR/dist/station-agent-linux-${ARCH}"

echo "Building SEA binary for linux/${ARCH}..."
mkdir -p "$AGENT_DIR/dist"

cd "$AGENT_DIR"

# 1. Bundle all JS into a single CJS file
echo "Bundling with esbuild..."
npx esbuild src/server.js \
  --bundle \
  --platform=node \
  --target=node20 \
  --format=cjs \
  --outfile=dist/bundle.js \
  --external:node:fs \
  --external:node:path \
  --external:node:http \
  --external:node:child_process \
  --external:node:os \
  --external:node:url \
  --external:node:fs/promises

# 2. Generate SEA blob
echo "Generating SEA blob..."
node --experimental-sea-config sea-config.json

# 3. Copy node binary and inject blob
echo "Injecting blob into binary..."
cp "$(which node)" "$OUT"

# Remove existing signature on macOS (required before postject)
if [[ "$(uname)" == "Darwin" ]]; then
  codesign --remove-signature "$OUT" 2>/dev/null || true
fi

npx postject "$OUT" NODE_SEA_BLOB dist/sea-prep.blob \
  --sentinel-fuse NODE_SEA_FUSE_fce680ab2cc467b6e072b8b5df1996b2 \
  --macho-segment-name NODE_SEA 2>/dev/null || \
npx postject "$OUT" NODE_SEA_BLOB dist/sea-prep.blob \
  --sentinel-fuse NODE_SEA_FUSE_fce680ab2cc467b6e072b8b5df1996b2

# Re-sign on macOS
if [[ "$(uname)" == "Darwin" ]]; then
  codesign --sign - "$OUT" 2>/dev/null || true
fi

chmod +x "$OUT"

echo ""
echo "Done: $OUT"
echo "Deploy to Raspberry Pi:"
echo "  scp $OUT pi@<raspberry>:/opt/station-agent/station-agent"
