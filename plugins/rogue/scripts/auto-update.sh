#!/usr/bin/env bash
# Silent background plugin updater. Fired from sessionStart.
# Rate-limited to once per 24h via ~/.rogue/.auto-update-check-cursor.
# Opt-outs:
#   ROGUE_AUTO_UPDATE=0       — disable entirely
#   ROGUE_PLUGIN_VERSION=v1.x — pin a version, never updates
set -u

LOG="$HOME/.rogue/auto-update-cursor.log"
mkdir -p "$(dirname "$LOG")" 2>/dev/null || exit 0
exec >>"$LOG" 2>&1
date "+%F %T --- auto-update tick (cursor) ---"

[ -r /etc/rogue/env ] && . /etc/rogue/env
[ -r "$HOME/.rogue-env" ] && . "$HOME/.rogue-env"

if [ "${ROGUE_AUTO_UPDATE:-1}" = "0" ]; then
  echo "ROGUE_AUTO_UPDATE=0, skipping"; exit 0
fi
if [ -n "${ROGUE_PLUGIN_VERSION:-}" ]; then
  echo "ROGUE_PLUGIN_VERSION=$ROGUE_PLUGIN_VERSION pinned, skipping"; exit 0
fi

CACHE="$HOME/.rogue/.auto-update-check-cursor"
TTL=86400
if [ -f "$CACHE" ]; then
  NOW=$(date +%s 2>/dev/null || echo 0)
  MTIME=$(stat -f %m "$CACHE" 2>/dev/null || stat -c %Y "$CACHE" 2>/dev/null || echo 0)
  if [ $((NOW - MTIME)) -lt "$TTL" ]; then echo "within TTL, skipping"; exit 0; fi
fi
touch "$CACHE" 2>/dev/null

REPO="${ROGUE_PLUGIN_REPO:-qualifire-dev/rogue-plugin-cursor}"
PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN_JSON="$PLUGIN_ROOT/.cursor-plugin/plugin.json"
if [ ! -f "$PLUGIN_JSON" ]; then echo "no plugin.json at $PLUGIN_JSON"; exit 0; fi

INSTALLED=$(python3 -c 'import json,sys;print(json.load(sys.stdin).get("version",""))' < "$PLUGIN_JSON" 2>/dev/null || echo "")
[ -z "$INSTALLED" ] && { echo "no installed version"; exit 0; }
INSTALLED_TAG="v${INSTALLED}"

LATEST=$(curl -fsSL --max-time 5 "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null \
  | python3 -c 'import json,sys;d=json.loads(sys.stdin.read() or "{}");print(d.get("tag_name") or "")' 2>/dev/null || echo "")
[ -z "$LATEST" ] && { echo "could not resolve latest release"; exit 0; }

if [ "$LATEST" = "$INSTALLED_TAG" ]; then echo "up to date at $INSTALLED_TAG"; exit 0; fi

echo "upgrade available: $INSTALLED_TAG -> $LATEST, running installer"
INSTALLER_URL="${ROGUE_CURSOR_INSTALLER_URL:-https://raw.githubusercontent.com/qualifire-dev/rogue-plugin-cursor/main/install.sh}"
curl -fsSL --max-time 60 "$INSTALLER_URL" | ROGUE_NON_INTERACTIVE=1 bash
echo "installer exited rc=$?"
