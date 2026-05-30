#!/usr/bin/env bash
# Shared per-repo profile slug helper (design §4.2). Sourced by the SessionStart hook and flush.sh so
# there is ONE definition of superpowers-<slug>. Executed directly, prints the slug for $1 (or $PWD).
# repo_slug <cwd> -> "superpowers-<sanitized>" (git remote basename if present, else cwd basename);
# never a bare "superpowers-".

repo_slug() {
  local cwd="${1:-$PWD}" url base
  url="$(git -C "${cwd}" config --get remote.origin.url 2>/dev/null || true)"
  url="${url%/}"
  if [ -n "${url}" ]; then base="${url##*/}"; base="${base%.git}"; else base="$(basename "${cwd}")"; fi
  base="$(printf '%s' "${base}" | tr '[:upper:] ' '[:lower:]-' | tr -cd '[:alnum:]-')"
  while [ "${base#-}" != "${base}" ]; do base="${base#-}"; done
  while [ "${base%-}" != "${base}" ]; do base="${base%-}"; done
  [ -n "${base}" ] || base="unknown"
  printf 'superpowers-%s' "${base}"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  repo_slug "${1:-$PWD}"
fi
