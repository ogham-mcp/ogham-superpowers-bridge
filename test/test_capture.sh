#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${DIR}/.." && pwd)"
CAP="${ROOT}/scripts/capture.sh"
rc=0
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
buf="${work}/.superpowers-lessons.jsonl"

# 1. invalid type rejected (non-zero, nothing written)
if SUPERPOWERS_BUFFER="$buf" bash "$CAP" --type bogus --task t1 "x" 2>/dev/null; then
  echo "  type: expected rejection of invalid --type"; rc=1; fi
[ ! -s "$buf" ] || { echo "  type: nothing should be written on rejection"; rc=1; }

# 2. valid capture appends one JSONL line with the right fields
SUPERPOWERS_BUFFER="$buf" bash "$CAP" --type tooling-fact --task task-7 "test runner is bash test/run.sh" >/dev/null 2>&1
[ "$(wc -l < "$buf" | tr -d ' ')" = "1" ] || { echo "  append: expected 1 line"; rc=1; }
python3 - "$buf" <<'PY' || rc=1
import json,sys
d=json.loads(open(sys.argv[1]).read().splitlines()[0])
assert d["type"]=="tooling-fact", d
assert d["source_task"]=="task-7", d
assert "test runner" in d["text"], d
assert d["when"] and d["tags"]==["type:tooling-fact"], d
assert "commit" in d
PY

# 3. over-long text rejected
big="$(head -c 2500 < /dev/zero | tr '\0' 'a')"
if SUPERPOWERS_BUFFER="$buf" bash "$CAP" --type decision --task t "$big" 2>/dev/null; then
  echo "  length: expected rejection of >2000 char text"; rc=1; fi
exit "$rc"
