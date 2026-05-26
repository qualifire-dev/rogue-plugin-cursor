#!/usr/bin/env bash
set -euo pipefail
# Build per-OS tarballs from the repo root.
# Contents are identical across platforms (pure JSON/Python/shell);
# the per-OS names exist so install.sh can fetch the right asset name
# and so we can swap in platform-specific files later without churn.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION=$(python3 -c 'import json;print(json.load(open("plugins/rogue/.cursor-plugin/plugin.json"))["version"])')
echo "Building rogue-plugin-cursor v${VERSION}"

mkdir -p dist

for OS in darwin linux; do
  OUT="dist/rogue-plugin-cursor-${OS}.tar.gz"
  rm -f "$OUT"
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
done
