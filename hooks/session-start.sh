#!/usr/bin/env bash
# SessionStart hook (design §4.2, §13.3, §14.5). Best-effort: ALWAYS exits 0.
# 1) eager per-repo profile bootstrap  2) ogham-version drift check  3) orphan-buffer report.
set -uo pipefail   # deliberately NOT -e: every failure must still reach exit 0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}"

STDIN_JSON="$(cat 2>/dev/null || true)"
CWD="$(printf '%s' "${STDIN_JSON}" | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
[ -n "${CWD}" ] || CWD="$PWD"

OGHAM="$(bash "${ROOT}/scripts/ogham-bin.sh" 2>/dev/null || true)"
if [ -z "${OGHAM}" ]; then
  echo "superpowers-memory: ogham binary not found; recall disabled this session (run scripts/install-tools.sh)."
  exit 0
fi

# Per-repo profile slug: git remote basename, else cwd basename; sanitized.
# Never emits a bare "superpowers-" (which would collide across repos).
repo_slug() {
  local url base
  url="$(git -C "${CWD}" config --get remote.origin.url 2>/dev/null || true)"
  url="${url%/}"   # tolerate a trailing slash on the remote URL
  if [ -n "${url}" ]; then base="${url##*/}"; base="${base%.git}"; else base="$(basename "${CWD}")"; fi
  base="$(printf '%s' "${base}" | tr '[:upper:] ' '[:lower:]-' | tr -cd '[:alnum:]-')"
  while [ "${base#-}" != "${base}" ]; do base="${base#-}"; done   # strip leading dashes
  while [ "${base%-}" != "${base}" ]; do base="${base%-}"; done   # strip trailing dashes
  [ -n "${base}" ] || base="unknown"
  printf 'superpowers-%s' "${base}"
}
PROFILE="$(repo_slug)"

# 1. eager profile bootstrap (auto-create on switch)
"${OGHAM}" profile switch "${PROFILE}" >/dev/null 2>&1 || true

# 2. binary drift check (ogham version subcommand -> JSON .version)
INSTALLED="$("${OGHAM}" version 2>/dev/null | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
PINNED="$(tr -d '[:space:]' < "${ROOT}/.tools/.version" 2>/dev/null || true)"
if [ -n "${PINNED}" ] && [ -n "${INSTALLED}" ] && [ "${INSTALLED}" != "${PINNED}" ]; then
  echo "superpowers-memory: ogham version drift (installed ${INSTALLED}, pinned ${PINNED}). Run scripts/install-tools.sh --upgrade."
fi

# 3. orphan-buffer report (distilled flush is gated on the §8.2 benchmark -- v0.1 only reports)
BUFFER="${CWD}/.superpowers-lessons.jsonl"
if [ -s "${BUFFER}" ]; then
  n="$(wc -l < "${BUFFER}" | tr -d ' ')"
  echo "superpowers-memory: orphaned staging buffer (${n} candidates) -- run /superpowers-memory:flush to distill."
fi

exit 0
