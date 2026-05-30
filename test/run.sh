#!/usr/bin/env bash
set -uo pipefail
shopt -s nullglob
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail=0
for t in "${DIR}"/test_*.sh; do
  echo "=== ${t##*/} ==="
  if bash "$t"; then echo "PASS: ${t##*/}"; else echo "FAIL: ${t##*/}"; fail=1; fi
done
exit "$fail"
