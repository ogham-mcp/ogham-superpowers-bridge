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

# 3. Loud-fail: run an ISOLATED copy (no sibling .tools/) with nothing else resolvable.
iso="$(mktemp -d)"; mkdir -p "${iso}/scripts"; cp "$RESOLVER" "${iso}/scripts/ogham-bin.sh"
if (unset OGHAM_BIN; PATH=/nonexistent CLAUDE_PLUGIN_ROOT=/nonexistent CLAUDE_PLUGIN_DATA=/nonexistent /bin/bash "${iso}/scripts/ogham-bin.sh" >/dev/null 2>&1); then
  echo "  loud-fail: expected non-zero exit"; rc=1
fi
err="$(unset OGHAM_BIN; PATH=/nonexistent CLAUDE_PLUGIN_ROOT=/nonexistent CLAUDE_PLUGIN_DATA=/nonexistent /bin/bash "${iso}/scripts/ogham-bin.sh" 2>&1 >/dev/null)"
case "$err" in *"no ogham binary found"*) : ;; *) echo "  loud-fail: expected stderr diagnostic, got '$err'"; rc=1 ;; esac
rm -rf "$iso"

# 4. Self-location regression (the live-demo bug): from a FOREIGN cwd, with no OGHAM_BIN and no
#    CLAUDE_PLUGIN_ROOT, the real resolver still finds the plugin's own .tools/ogham.
got4="$(cd /tmp && unset OGHAM_BIN; unset CLAUDE_PLUGIN_ROOT; bash "$RESOLVER" 2>/dev/null)"
[ "$got4" = "${ROOT}/.tools/ogham" ] || { echo "  self-locate: expected ${ROOT}/.tools/ogham from foreign cwd, got '$got4'"; rc=1; }
exit "$rc"
