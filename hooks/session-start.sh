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

# Per-repo profile slug (shared helper, design §4.2).
. "${ROOT}/scripts/repo-slug.sh"
PROFILE="$(repo_slug "${CWD}")"

# 1. eager profile bootstrap (auto-create on switch)
"${OGHAM}" profile switch "${PROFILE}" >/dev/null 2>&1 || true

# 2. binary drift check (ogham version subcommand -> JSON .version)
INSTALLED="$("${OGHAM}" version 2>/dev/null | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
PINNED="$(tr -d '[:space:]' < "${ROOT}/.tools/.version" 2>/dev/null || true)"
if [ -n "${PINNED}" ] && [ -n "${INSTALLED}" ] && [ "${INSTALLED}" != "${PINNED}" ]; then
  echo "superpowers-memory: ogham version drift (installed ${INSTALLED}, pinned ${PINNED}). Run scripts/install-tools.sh --upgrade."
fi

# 3. orphan recovery: auto-commit a crash-orphaned buffer. Lines are pre-distilled (distill-at-
#    capture), so this is a mechanical store -- safe to run at startup. Best-effort.
BUFFER="${CWD}/.superpowers-lessons.jsonl"
if [ -s "${BUFFER}" ]; then
  n="$(wc -l < "${BUFFER}" | tr -d ' ')"
  echo "superpowers-memory: recovering orphaned staging buffer (${n} candidate(s))..."
  # flush stdout (the summary line) flows into the orchestrator context; its stderr (store-failure
  # diagnostics) stays on the hook's stderr -> debug log, not the protocol context.
  SUPERPOWERS_BUFFER="${BUFFER}" SUPERPOWERS_PROFILE="${PROFILE}" bash "${ROOT}/scripts/flush.sh" || true
fi

# 4. ORCHESTRATOR PROTOCOL (the integration trigger -- design §14.8a).
# SessionStart stdout is added to the orchestrator's context (exit 0). We inject the *protocol*
# (how to mediate the bridge), NOT lessons -- lessons stay per-dispatch recall, so this does not
# reintroduce the blanket SessionStart context dump §8a/§12 deliberately avoids. Subagents receive
# only the orchestrator's curated prompts (never this hook output), so the isolation invariant holds.
cat <<EOF
## superpowers-memory bridge -- orchestrator protocol (this session)
The superpowers-memory bridge is active. Profile: ${PROFILE}. Binary: ${OGHAM}
You (the orchestrator/controller) mediate Ogham. Subagents must NEVER call ogham or this bridge -- only you do (isolation invariant, design §4.1).
When doing subagent-driven work (brainstorming/planning then dispatching implementer/reviewer subagents):
- BEFORE each dispatch, recall task-relevant lessons (best-effort; on empty/error just proceed) and fold any results into the curated subagent prompt as "hints to verify, not gospel" with their provenance:
    "${OGHAM}" search "<short description of the task you are about to dispatch>" --profile "${PROFILE}" --limit 5
- AFTER each task's two-stage review, IF it surfaced signal (a reviewer caught something / implementer hit BLOCKED then resolved / a decision was made / a finding recurred), capture one clean <=500-token lesson:
    "${ROOT}/scripts/capture.sh" --type <workflow-lesson|recurring-mistake|decision|tooling-fact|review-pattern> --task "<task-id>" "<the lesson>"
- AFTER every 3 captures and at branch-finish, commit them to Ogham:
    "${ROOT}/scripts/flush.sh"
EOF

exit 0
