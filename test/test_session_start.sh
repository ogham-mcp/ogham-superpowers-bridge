#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${DIR}/.." && pwd)"
HOOK="${ROOT}/hooks/session-start.sh"
rc=0
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

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
: > "${work}/c"
printf '{"cwd":"%s"}' "$work" | OGHAM_BIN="$fake" FAKE_VERSION=0.7.3 OGHAM_CALLS="${work}/c" bash "$HOOK" >/dev/null 2>&1
[ $? -eq 0 ] || { echo "  exit: expected 0"; rc=1; }

# 2. Bootstraps a non-empty superpowers-<slug> profile (never a bare 'superpowers-')
out_calls="${work}/calls2"; : > "$out_calls"
printf '{"cwd":"%s"}' "$work" | OGHAM_BIN="$fake" FAKE_VERSION=0.7.3 OGHAM_CALLS="$out_calls" bash "$HOOK" >/dev/null 2>&1
grep -qE '^superpowers-[a-z0-9]' "$out_calls" || { echo "  profile: expected superpowers-<slug>, got '$(cat "$out_calls")'"; rc=1; }

# 3. Drift warning when installed != pinned -- hermetic fixture ROOT (does NOT touch the real .tools/.version).
#    The fixture must contain scripts/ogham-bin.sh so the hook can resolve the (fake) binary via OGHAM_BIN.
fixroot="$(mktemp -d)"
mkdir -p "${fixroot}/scripts" "${fixroot}/.tools"
cp "${ROOT}/scripts/ogham-bin.sh" "${fixroot}/scripts/ogham-bin.sh"
cp "${ROOT}/scripts/repo-slug.sh" "${fixroot}/scripts/repo-slug.sh"
printf '0.7.3\n' > "${fixroot}/.tools/.version"
drift="$(printf '{"cwd":"%s"}' "$work" | OGHAM_BIN="$fake" FAKE_VERSION=0.9.9 OGHAM_CALLS="${work}/c3" CLAUDE_PLUGIN_ROOT="$fixroot" bash "$HOOK" 2>&1)"
echo "$drift" | grep -qi 'drift' || { echo "  drift: expected drift warning, got '$drift'"; rc=1; }
rm -rf "$fixroot"

# 4. Orphan-buffer report when buffer is non-empty
echo '{"type":"decision","text":"x"}' > "${work}/.superpowers-lessons.jsonl"
orphan="$(printf '{"cwd":"%s"}' "$work" | OGHAM_BIN="$fake" FAKE_VERSION=0.7.3 OGHAM_CALLS="${work}/c4" bash "$HOOK" 2>&1)"
echo "$orphan" | grep -qi 'orphan' || { echo "  orphan: expected orphaned-buffer report"; rc=1; }

# 5. Orchestrator protocol (integration trigger) is emitted, references the profile + the recall command,
#    and states the subagent-isolation rule.
proto="$(printf '{"cwd":"%s"}' "$work" | OGHAM_BIN="$fake" FAKE_VERSION=0.7.3 OGHAM_CALLS="${work}/c5" bash "$HOOK" 2>&1)"
echo "$proto" | grep -qi 'orchestrator protocol' || { echo "  protocol: expected orchestrator protocol block"; rc=1; }
echo "$proto" | grep -q 'search' || { echo "  protocol: expected the recall (search) command"; rc=1; }
echo "$proto" | grep -qiE 'subagents? must never' || { echo "  protocol: expected the subagent-isolation rule"; rc=1; }

exit "$rc"
