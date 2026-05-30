#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${DIR}/.." && pwd)"
RESOLVER="${ROOT}/scripts/ogham-bin.sh"
rc=0

# 1. OGHAM_BIN override wins when executable
tmp="$(mktemp)"; chmod +x "$tmp"
got="$(OGHAM_BIN="$tmp" CLAUDE_PLUGIN_ROOT=/nonexistent bash "$RESOLVER" 2>/dev/null)"
[ "$got" = "$tmp" ] || { echo "  override: expected $tmp got '$got'"; rc=1; }
rm -f "$tmp"

# 2. Falls back to CLAUDE_PLUGIN_ROOT/.tools/ogham
got="$(unset OGHAM_BIN; CLAUDE_PLUGIN_ROOT="$ROOT" bash "$RESOLVER" 2>/dev/null)"
[ "$got" = "${ROOT}/.tools/ogham" ] || { echo "  plugin-root: expected ${ROOT}/.tools/ogham got '$got'"; rc=1; }

# 3. Loud-fail when nothing resolvable
if (unset OGHAM_BIN; PATH=/nonexistent CLAUDE_PLUGIN_ROOT=/nonexistent CLAUDE_PLUGIN_DATA=/nonexistent bash "$RESOLVER" >/dev/null 2>&1); then
  echo "  loud-fail: expected non-zero exit"; rc=1
fi
exit "$rc"
