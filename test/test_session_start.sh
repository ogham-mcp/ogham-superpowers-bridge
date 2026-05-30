#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${DIR}/.." && pwd)"
HOOK="${ROOT}/hooks/session-start.sh"
rc=0
work="$(mktemp -d)"

# Fake ogham: records 'profile switch' args, emits version JSON matching $FAKE_VERSION.
fake="${work}/ogham"
cat > "$fake" <<'FAKE'
#!/usr/bin/env bash
if [ "$1" = "profile" ] && [ "$2" = "switch" ]; then echo "$3" >> "${OGHAM_CALLS}"; exit 0; fi
if [ "$1" = "version" ]; then printf '{"version": "%s"}\n' "${FAKE_VERSION:-0.7.3}"; exit 0; fi
exit 0
FAKE
chmod +x "$fake"

# 1. Always exits 0
printf '{"cwd":"%s"}' "$work" | OGHAM_BIN="$fake" FAKE_VERSION=0.7.3 OGHAM_CALLS="${work}/c" bash "$HOOK" >/dev/null 2>&1
[ $? -eq 0 ] || { echo "  exit: expected 0"; rc=1; }

# 2. Bootstraps a superpowers-<slug> profile
out_calls="${work}/calls2"; : > "$out_calls"
printf '{"cwd":"%s"}' "$work" | OGHAM_BIN="$fake" FAKE_VERSION=0.7.3 OGHAM_CALLS="$out_calls" bash "$HOOK" >/dev/null 2>&1
grep -q '^superpowers-' "$out_calls" || { echo "  profile: expected superpowers-* switch, got '$(cat "$out_calls")'"; rc=1; }

# 3. Drift warning when installed != pinned
printf '0.7.3\n' > "${ROOT}/.tools/.version"
drift="$(printf '{"cwd":"%s"}' "$work" | OGHAM_BIN="$fake" FAKE_VERSION=0.9.9 OGHAM_CALLS="${work}/c3" bash "$HOOK" 2>&1)"
echo "$drift" | grep -qi 'drift' || { echo "  drift: expected drift warning"; rc=1; }

# 4. Orphan-buffer report when buffer is non-empty
echo '{"type":"decision","text":"x"}' > "${work}/.superpowers-lessons.jsonl"
orphan="$(printf '{"cwd":"%s"}' "$work" | OGHAM_BIN="$fake" FAKE_VERSION=0.7.3 OGHAM_CALLS="${work}/c4" bash "$HOOK" 2>&1)"
echo "$orphan" | grep -qi 'orphan' || { echo "  orphan: expected orphaned-buffer report"; rc=1; }

rm -rf "$work"
exit "$rc"
