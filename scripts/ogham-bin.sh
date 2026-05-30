#!/usr/bin/env bash
# Resolve the pinned ogham binary (design §13.2 / §14.3).
# Prints the absolute path on stdout; exits 1 with a stderr message if none found.
# Resolution order: $OGHAM_BIN -> ${CLAUDE_PLUGIN_ROOT:-$PWD}/.tools/ogham
#                   -> ${CLAUDE_PLUGIN_DATA}/bin/ogham -> command -v ogham (PATH fallback)
#                   -> loud-fail (stderr + return 1)

resolve_ogham_bin() {
  if [ -n "${OGHAM_BIN:-}" ] && [ -x "${OGHAM_BIN}" ]; then
    printf '%s\n' "${OGHAM_BIN}"; return 0
  fi
  local root="${CLAUDE_PLUGIN_ROOT:-$PWD}"
  if [ -x "${root}/.tools/ogham" ]; then
    printf '%s\n' "${root}/.tools/ogham"; return 0
  fi
  if [ -n "${CLAUDE_PLUGIN_DATA:-}" ] && [ -x "${CLAUDE_PLUGIN_DATA}/bin/ogham" ]; then
    printf '%s\n' "${CLAUDE_PLUGIN_DATA}/bin/ogham"; return 0
  fi
  if command -v ogham >/dev/null 2>&1; then
    command -v ogham; return 0
  fi
  echo "ogham-bin: no ogham binary found (set OGHAM_BIN or run scripts/install-tools.sh)" >&2
  return 1
}

# Executed directly -> set strict options and print path. Sourced -> only define
# the function, leaving the caller's shell options untouched (the function's own
# variable refs are already :- guarded, so it is safe without set -u).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  set -uo pipefail
  resolve_ogham_bin
fi
