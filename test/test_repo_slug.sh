#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${DIR}/.." && pwd)"
HELPER="${ROOT}/scripts/repo-slug.sh"
rc=0

# Executed directly: prints superpowers-<basename> for a non-git dir
d="$(mktemp -d)/My Repo--"; mkdir -p "$d"
got="$(bash "$HELPER" "$d")"
[ "$got" = "superpowers-my-repo" ] || { echo "  slug: expected superpowers-my-repo got '$got'"; rc=1; }

# Sourced: defines repo_slug without side effects
got2="$(. "$HELPER"; repo_slug "$d")"
[ "$got2" = "superpowers-my-repo" ] || { echo "  sourced: expected superpowers-my-repo got '$got2'"; rc=1; }

# Empty/edge cwd never yields a bare 'superpowers-'
got3="$(bash "$HELPER" "/")"
case "$got3" in superpowers-?*) : ;; *) echo "  edge: bare/empty slug '$got3'"; rc=1 ;; esac
exit "$rc"
