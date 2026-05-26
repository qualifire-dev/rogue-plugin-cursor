#!/usr/bin/env bash
set -euo pipefail
# Build dist/rogue-plugin-cursor-darwin.tar.gz from the repo root.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION=$(python3 -c 'import json;print(json.load(open("plugins/rogue/.cursor-plugin/plugin.json"))["version"])')
echo "Building rogue-plugin-cursor v${VERSION}"

mkdir -p dist
OUT="dist/rogue-plugin-cursor-darwin.tar.gz"
rm -f "$OUT"

# Tarball includes only what the installer needs.
tar -czf "$OUT" \
  --exclude='__pycache__' \
  --exclude='*.pyc' \
  .cursor-plugin/marketplace.json \
  plugins/rogue/.cursor-plugin/ \
  plugins/rogue/hooks/ \
  plugins/rogue/scripts/ \
  plugins/rogue/commands/

ls -la "$OUT"
echo "Built $OUT"
