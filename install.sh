#!/usr/bin/env bash
set -euo pipefail
# Rogue Security — one-line installer for Cursor.
#   curl -fsSL https://raw.githubusercontent.com/qualifire-dev/rogue-plugin-cursor/main/install.sh | bash
# With credentials:
#   curl -fsSL .../install.sh | ROGUE_API_KEY=rsk_xxx ROGUE_ACTOR_EMAIL=you@co.com ROGUE_ACTOR_NAME='Your Name' bash
# Flags:
#   --api-key KEY --email EMAIL --name NAME --api-url URL
#   --local PATH        (use a local source dir, skip download)
#   --non-interactive   (fail rather than prompt)

ROGUE_API_URL_DEFAULT="https://api.rogue.security"
PLUGIN_REPO="${ROGUE_PLUGIN_REPO:-qualifire-dev/rogue-plugin-cursor}"
PLUGIN_VERSION_PIN="${ROGUE_PLUGIN_VERSION:-}"
PLUGIN_NAME="rogue"

CURSOR_DIR="$HOME/.cursor"
PLUGIN_INSTALL_DIR="$CURSOR_DIR/plugins/local/${PLUGIN_NAME}"
ENV_FILE="${ROGUE_ENV_FILE:-$HOME/.rogue-env}"

API_KEY="${ROGUE_API_KEY:-}"; ACTOR_EMAIL="${ROGUE_ACTOR_EMAIL:-}"; ACTOR_NAME="${ROGUE_ACTOR_NAME:-}"
API_URL="${ROGUE_API_URL:-$ROGUE_API_URL_DEFAULT}"
NON_INTERACTIVE="${ROGUE_NON_INTERACTIVE:-}"; LOCAL_PATH="${ROGUE_LOCAL_PATH:-}"

TMPDIR_LOCAL=""
cleanup() { [ -n "$TMPDIR_LOCAL" ] && rm -rf "$TMPDIR_LOCAL" || true; }
trap cleanup EXIT

log()  { printf "→ %s\n" "$*"; }
warn() { printf "⚠ %s\n" "$*" >&2; }
err()  { printf "✗ %s\n" "$*" >&2; exit 1; }
need_arg() {
  if [ $# -lt 2 ] || [ -z "${2:-}" ]; then
    err "$1 requires a value"
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    --api-key)         need_arg "$@"; API_KEY="$2"; shift 2 ;;
    --email)           need_arg "$@"; ACTOR_EMAIL="$2"; shift 2 ;;
    --name)            need_arg "$@"; ACTOR_NAME="$2"; shift 2 ;;
    --api-url)         need_arg "$@"; API_URL="$2"; shift 2 ;;
    --local)           need_arg "$@"; LOCAL_PATH="$2"; shift 2 ;;
    --non-interactive) NON_INTERACTIVE=1; shift ;;
    *) shift ;;
  esac
done

case "$(uname -s)" in
  Darwin) OS=darwin ;;
  Linux)  err "Linux support is not shipped yet" ;;
  *)      err "Unsupported platform: $(uname -s)" ;;
esac
log "Platform: $OS"

command -v python3 >/dev/null 2>&1 || err "python3 required (xcode-select --install on macOS)"
command -v curl    >/dev/null 2>&1 || err "curl required"

prompt_tty() {
  local var="$1" text="$2" secret="${3:-}"
  if [ -n "$NON_INTERACTIVE" ]; then err "$var not set and --non-interactive on"; fi
  [ -r /dev/tty ] || err "$var not set and no TTY"
  local value
  if [ "$secret" = "secret" ]; then
    printf "%s: " "$text" > /dev/tty; IFS= read -r -s value < /dev/tty; printf "\n" > /dev/tty
  else
    printf "%s: " "$text" > /dev/tty; IFS= read -r value < /dev/tty
  fi
  [ -n "$value" ] || err "$var cannot be empty."
  printf -v "$var" '%s' "$value"
}

[ -n "$API_KEY" ] || prompt_tty API_KEY "Rogue API key (rsk_...)" secret

if [ -z "$ACTOR_EMAIL" ] && command -v git >/dev/null 2>&1; then ACTOR_EMAIL=$(git config --global user.email 2>/dev/null || true); fi
if [ -z "$ACTOR_NAME"  ] && command -v git >/dev/null 2>&1; then ACTOR_NAME=$(git config --global user.name 2>/dev/null || true); fi
[ -n "$ACTOR_EMAIL" ] || ACTOR_EMAIL="$(whoami)@$(hostname -s 2>/dev/null || hostname)"
[ -n "$ACTOR_NAME"  ] || ACTOR_NAME="$(whoami)"
log "Actor: $ACTOR_NAME <$ACTOR_EMAIL>"

# Validate
HTTP_CODE=$(curl -sS -o /dev/null -w "%{http_code}" --max-time 10 \
  -H "x-rogue-api-key: $API_KEY" "$API_URL/api/v1/hooks/ping" 2>/dev/null || echo 000)
[ "$HTTP_CODE" = "200" ] || err "API key validation failed (HTTP $HTTP_CODE)"
log "API key valid."

# Write env file
umask 077
: > "$ENV_FILE"
{
  printf '# Managed by the rogue Cursor plugin installer.\n'
  printf 'export ROGUE_API_KEY=%q\n' "$API_KEY"
  printf 'export ROGUE_ACTOR_EMAIL=%q\n' "$ACTOR_EMAIL"
  printf 'export ROGUE_ACTOR_NAME=%q\n' "$ACTOR_NAME"
  [ "$API_URL" != "$ROGUE_API_URL_DEFAULT" ] && printf 'export ROGUE_BASE_URL=%q\n' "$API_URL"
} >> "$ENV_FILE"
chmod 600 "$ENV_FILE"
log "Wrote $ENV_FILE (mode 600)"

# Source plugin: local OR download
TMPDIR_LOCAL=$(mktemp -d)
if [ -n "$LOCAL_PATH" ]; then
  LOCAL_PATH=$(cd "$LOCAL_PATH" && pwd)
  [ -f "$LOCAL_PATH/plugins/${PLUGIN_NAME}/.cursor-plugin/plugin.json" ] \
    || err "--local path missing plugin manifest"
  SRC_DIR="$LOCAL_PATH"
else
  ASSET="rogue-plugin-cursor-${OS}.tar.gz"
  URL="https://github.com/${PLUGIN_REPO}/releases/latest/download/${ASSET}"
  [ -n "$PLUGIN_VERSION_PIN" ] && URL="https://github.com/${PLUGIN_REPO}/releases/download/${PLUGIN_VERSION_PIN}/${ASSET}"
  log "Downloading: $URL"
  curl -fsSL --max-time 60 -o "$TMPDIR_LOCAL/p.tar.gz" "$URL" \
    || err "Download failed from $URL"
  mkdir -p "$TMPDIR_LOCAL/extract"
  tar -xzf "$TMPDIR_LOCAL/p.tar.gz" -C "$TMPDIR_LOCAL/extract"
  SRC_DIR="$TMPDIR_LOCAL/extract"
fi

PLUGIN_SRC="$SRC_DIR/plugins/${PLUGIN_NAME}"
[ -f "$PLUGIN_SRC/.cursor-plugin/plugin.json" ] || err "Missing plugin manifest in source"

# Install
mkdir -p "$(dirname "$PLUGIN_INSTALL_DIR")"
rm -rf "$PLUGIN_INSTALL_DIR"
mkdir -p "$PLUGIN_INSTALL_DIR"
cp -R "$PLUGIN_SRC/." "$PLUGIN_INSTALL_DIR/"
log "Installed → $PLUGIN_INSTALL_DIR"

# If Cursor doesn't expose CURSOR_PLUGIN_ROOT at hook runtime (verified in
# Task 5.1), templatize hooks.json to the absolute install path.
if [ "${ROGUE_TEMPLATE_HOOKS:-1}" = "1" ]; then
  HOOKS_FILE="$PLUGIN_INSTALL_DIR/hooks/hooks.json"
  if [ -f "$HOOKS_FILE" ]; then
    ROGUE_HOOKS_PATH="$HOOKS_FILE" ROGUE_INSTALL_ROOT="$PLUGIN_INSTALL_DIR" python3 - <<'PY'
import json, os
p = os.environ["ROGUE_HOOKS_PATH"]
root = os.environ["ROGUE_INSTALL_ROOT"]
with open(p) as f:
    d = json.load(f)
for ev, entries in d.get("hooks", {}).items():
    for e in entries:
        if "command" in e:
            e["command"] = e["command"].replace("${CURSOR_PLUGIN_ROOT}", root)
with open(p, "w") as f:
    json.dump(d, f, indent=2)
PY
    log "Templated hook paths to $PLUGIN_INSTALL_DIR"
  fi
fi

cat <<EOF

✓ Rogue Security (Cursor) installed.

  Plugin:       $PLUGIN_INSTALL_DIR
  Credentials:  $ENV_FILE  (mode 600)

Next steps:
  1. Fully quit Cursor and reopen.
  2. Run /rogue:status inside Cursor to verify.
  3. AIDR dashboard: https://app.rogue.security/aidr

Re-running this installer upgrades the plugin and is safe.
EOF
