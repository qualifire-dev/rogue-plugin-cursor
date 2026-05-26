#!/usr/bin/env bash
# Build a self-contained, pre-configured Rogue plugin tarball for Cursor.
#
# The resulting tarball can be extracted into ~/.cursor/plugins/local/rogue/
# (or distributed via MDM) without the customer running /rogue:setup — the
# API key is baked into an `env` file at the plugin root, sourced by the
# dispatcher before /etc/rogue/env and ~/.rogue-env (which still override
# if present).
#
# Actor identity (email/name) is intentionally NOT compiled in. It is
# derived per-user at hook-fire time inside the dispatcher (git config →
# whoami/hostname). Per-user ~/.rogue-env overrides still win.
#
# One-liner (admin runs this):
#   curl -fsSL https://raw.githubusercontent.com/qualifire-dev/rogue-plugin-cursor/main/scripts/compile-customer-plugin.sh \
#     | bash -s -- --key rsk_xxx
#
# Local / interactive (prompts for missing args):
#   bash scripts/compile-customer-plugin.sh
#
# Args:
#   --key KEY        ROGUE_API_KEY (required)
#   --from vX.Y.Z    Source release tag (default: latest GitHub release)
#   --os darwin|linux  Source tarball OS (default: darwin)
#   --out PATH       Output tarball path (default: ./rogue-aidr-compiled-<ver>.tar.gz)
#   --base-url URL   Override ROGUE_BASE_URL (rare)
#   --repo OWNER/REPO  Source repo (default: qualifire-dev/rogue-plugin-cursor)
#   --local PATH     Use a local source tree instead of downloading a release.
#                    PATH should be the repo root (contains plugins/rogue/).
#
# Output: a flat tar.gz whose root contains .cursor-plugin/, hooks/,
# scripts/, commands/, and env. Customers extract into
# ~/.cursor/plugins/local/rogue/.

set -euo pipefail

REPO="qualifire-dev/rogue-plugin-cursor"
KEY=""; FROM=""; OUT=""; BASE_URL=""; OS=""; LOCAL_SRC=""

while [ $# -gt 0 ]; do
  case "$1" in
    --key)      KEY="$2"; shift 2 ;;
    --from)     FROM="$2"; shift 2 ;;
    --os)       OS="$2"; shift 2 ;;
    --out)      OUT="$2"; shift 2 ;;
    --base-url) BASE_URL="$2"; shift 2 ;;
    --repo)     REPO="$2"; shift 2 ;;
    --local)    LOCAL_SRC="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,33p' "$0" 2>/dev/null
      exit 0
      ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

# When invoked via `curl | bash`, stdin is the piped script — prompts must
# read from the terminal directly.
TTY=/dev/tty
[ -r "$TTY" ] && [ -w "$TTY" ] || TTY=""

prompt_key() {
  [ -n "$KEY" ] && return 0
  if [ -z "$TTY" ]; then
    echo "Missing --key (no TTY available for interactive prompt)" >&2
    exit 2
  fi
  printf "Rogue API key (rsk_...): " > "$TTY"
  IFS= read -r KEY < "$TTY"
}

prompt_key
[ -n "$KEY" ] || { echo "API key required" >&2; exit 2; }

case "${OS:-darwin}" in
  darwin|linux) OS="${OS:-darwin}" ;;
  *) echo "Bad --os: $OS (expected: darwin|linux)" >&2; exit 2 ;;
esac

for tool in tar python3; do
  command -v "$tool" >/dev/null 2>&1 || { echo "missing required tool: $tool" >&2; exit 1; }
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [ -n "$LOCAL_SRC" ]; then
  LOCAL_SRC="$(cd "$LOCAL_SRC" && pwd)"
  [ -d "$LOCAL_SRC/plugins/rogue/.cursor-plugin" ] || {
    echo "--local: expected $LOCAL_SRC/plugins/rogue/.cursor-plugin to exist" >&2
    exit 1
  }
  SRC="$LOCAL_SRC/plugins/rogue"
  FROM="$(python3 -c 'import json,sys;print("v"+json.load(open(sys.argv[1]))["version"])' \
    "$SRC/.cursor-plugin/plugin.json")"
  echo "-> using local source: $LOCAL_SRC (version $FROM)"
else
  command -v curl >/dev/null 2>&1 || { echo "missing required tool: curl" >&2; exit 1; }
  if [ -z "$FROM" ]; then
    echo "-> resolving latest release tag of $REPO..."
    FROM=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
      | python3 -c 'import sys,json; print(json.load(sys.stdin)["tag_name"])')
    [ -n "$FROM" ] || { echo "could not resolve latest tag" >&2; exit 1; }
  fi
  echo "-> using release: $FROM ($OS)"

  TARBALL_URL="https://github.com/${REPO}/releases/download/${FROM}/rogue-plugin-cursor-${OS}.tar.gz"
  echo "-> downloading $TARBALL_URL"
  curl -fsSL "$TARBALL_URL" -o "$WORK/src.tar.gz"
  mkdir -p "$WORK/extract"
  tar -xzf "$WORK/src.tar.gz" -C "$WORK/extract"
  SRC="$WORK/extract/plugins/rogue"
  [ -d "$SRC/.cursor-plugin" ] || {
    echo "unexpected tarball layout at $SRC" >&2
    exit 1
  }
fi

# Flatten: plugin root becomes the tarball root, so the customer extracts
# straight into ~/.cursor/plugins/local/rogue/.
STAGE="$WORK/rogue"
mkdir -p "$STAGE"
cp -R "$SRC"/. "$STAGE"/

# Bake the API key + config into ${CURSOR_PLUGIN_ROOT}/env. Actor identity
# is derived per-user at hook-fire time in the dispatcher (git config →
# whoami/hostname) so the same compiled tarball works for every user.
# ~/.rogue-env on the end-user's machine still overrides anything here.
{
  echo "# Compiled by compile-customer-plugin.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "# Source release: ${FROM}"
  printf 'export ROGUE_API_KEY=%q\n' "$KEY"
  [ -n "$BASE_URL" ] && printf 'export ROGUE_BASE_URL=%q\n' "$BASE_URL"
  # The bundled version is the truth — don't let auto-update clobber it.
  echo 'export ROGUE_AUTO_UPDATE=0'
} > "$STAGE/env"
chmod 600 "$STAGE/env"

VERSION_NO_V="${FROM#v}"
[ -n "$OUT" ] || OUT="$PWD/rogue-aidr-compiled-${VERSION_NO_V}.tar.gz"
rm -f "$OUT"

# Flat tar.gz: plugin contents at the tarball root, no wrapping directory.
# Customer extracts with:
#   mkdir -p ~/.cursor/plugins/local/rogue
#   tar -xzf rogue-aidr-compiled-*.tar.gz -C ~/.cursor/plugins/local/rogue
( cd "$STAGE" && tar -czf "$OUT" \
    --exclude='__pycache__' \
    --exclude='*.pyc' \
    . )

SIZE=$(wc -c < "$OUT" | awk '{print $1}')
KEY_TAIL="${KEY: -4}"

cat <<EOF

OK  wrote $OUT  (${SIZE} bytes)

  Plugin version: $FROM
  Key tail:       ...${KEY_TAIL}
  Actor:          (resolved per-user at runtime: git config → whoami/hostname)

!!  This tarball embeds ROGUE_API_KEY in plaintext. The key is an
    attribution token — it can only POST events to Rogue, not read or
    configure anything — but still distribute over trusted channels and
    rotate via the Rogue dashboard if leaked.

Customer install (per machine):
  mkdir -p ~/.cursor/plugins/local/rogue
  tar -xzf $(basename "$OUT") -C ~/.cursor/plugins/local/rogue
  # then fully quit and reopen Cursor; run /rogue:status to verify.

Tarball layout is flat — .cursor-plugin/, hooks/, scripts/, commands/, and
the compiled env sit at the tarball root, no wrapper directory.

EOF
