#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${DIR}/.." && pwd)"
FLUSH="${ROOT}/scripts/flush.sh"
rc=0
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT

# Fake ogham: records store calls; exits 1 when the stored text contains FAILME.
fake="${work}/ogham"
cat > "$fake" <<'FAKE'
#!/usr/bin/env bash
if [ "$1" = "store" ]; then
  echo "store $*" >> "${OGHAM_CALLS}"
  case "$*" in *FAILME*) exit 1 ;; *) exit 0 ;; esac
fi
exit 0
FAKE
chmod +x "$fake"

buf="${work}/.superpowers-lessons.jsonl"
printf '%s\n' '{"type":"decision","text":"keep A","when":"t","commit":"abc","source_task":"t1","tags":["type:decision"]}' > "$buf"
printf '%s\n' '{"type":"tooling-fact","text":"FAILME B","when":"t","commit":"abc","source_task":"t2","tags":["type:tooling-fact"]}' >> "$buf"

calls="${work}/calls"; : > "$calls"
out="$(OGHAM_BIN="$fake" OGHAM_CALLS="$calls" SUPERPOWERS_BUFFER="$buf" SUPERPOWERS_PROFILE="superpowers-test" bash "$FLUSH" 2>&1)"

# both lines attempted, with the scribe source tag
grep -q -- "--source superpowers-scribe" "$calls" || { echo "  store: expected --source superpowers-scribe"; rc=1; }
[ "$(grep -c '^store ' "$calls")" = "2" ] || { echo "  store: expected 2 store attempts, calls=$(cat "$calls")"; rc=1; }
# the failed (FAILME) line is retained; the successful line is gone
grep -q 'FAILME' "$buf" || { echo "  retain: expected FAILME line retained"; rc=1; }
grep -q 'keep A' "$buf" && { echo "  clear: expected 'keep A' removed after success"; rc=1; }
echo "$out" | grep -qi 'flushed 1' || { echo "  summary: expected 'flushed 1', got '$out'"; rc=1; }

# empty buffer -> nothing to flush
: > "$buf"
out2="$(OGHAM_BIN="$fake" OGHAM_CALLS="$calls" SUPERPOWERS_BUFFER="$buf" SUPERPOWERS_PROFILE="superpowers-test" bash "$FLUSH" 2>&1)"
echo "$out2" | grep -qi 'nothing to flush' || { echo "  empty: expected 'nothing to flush', got '$out2'"; rc=1; }
exit "$rc"
