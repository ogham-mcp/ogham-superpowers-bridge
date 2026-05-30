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

# 2. Falls back to ${CLAUDE_PLUGIN_ROOT}/.tools/ogham — hermetic fixture, no dependency on the real binary
fixroot="$(mktemp -d)"; mkdir -p "${fixroot}/.tools"
: > "${fixroot}/.tools/ogham"; chmod +x "${fixroot}/.tools/ogham"
got="$(unset OGHAM_BIN; CLAUDE_PLUGIN_ROOT="$fixroot" bash "$RESOLVER" 2>/dev/null)"
[ "$got" = "${fixroot}/.tools/ogham" ] || { echo "  plugin-root: expected ${fixroot}/.tools/ogham got '$got'"; rc=1; }
rm -rf "$fixroot"

# 3. Loud-fail when nothing resolvable: non-zero exit AND a stderr diagnostic
if (unset OGHAM_BIN; PATH=/nonexistent CLAUDE_PLUGIN_ROOT=/nonexistent CLAUDE_PLUGIN_DATA=/nonexistent /bin/bash "$RESOLVER" >/dev/null 2>&1); then
  echo "  loud-fail: expected non-zero exit"; rc=1
fi
err="$(unset OGHAM_BIN; PATH=/nonexistent CLAUDE_PLUGIN_ROOT=/nonexistent CLAUDE_PLUGIN_DATA=/nonexistent /bin/bash "$RESOLVER" 2>&1 >/dev/null)"
case "$err" in
  *"no ogham binary found"*) : ;;
  *) echo "  loud-fail: expected stderr diagnostic, got '$err'"; rc=1 ;;
esac
exit "$rc"
