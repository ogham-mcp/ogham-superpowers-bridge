#!/usr/bin/env bash
# Capture one distilled lesson to the staging buffer (scribe spec; design §4.3/§5).
# Run by the orchestrator after a task's two-stage review ONLY IF signal surfaced.
# Usage: capture.sh --type <taxonomy> --task "<task-id>" "<lesson text>"
set -uo pipefail

BUFFER="${SUPERPOWERS_BUFFER:-$PWD/.superpowers-lessons.jsonl}"
TAXONOMY="workflow-lesson recurring-mistake decision tooling-fact review-pattern"

TYPE=""; TASK=""; TEXT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --type) TYPE="${2:-}"; shift ;;
    --task) TASK="${2:-}"; shift ;;
    -h|--help) echo "usage: capture.sh --type <one of: ${TAXONOMY}> --task <id> \"<lesson>\""; exit 0 ;;
    *) TEXT="${TEXT:+$TEXT }$1" ;;
  esac
  shift
done

[ -n "${TYPE}" ] || { echo "capture: --type required" >&2; exit 2; }
case " ${TAXONOMY} " in *" ${TYPE} "*) : ;; *) echo "capture: invalid --type '${TYPE}' (allowed: ${TAXONOMY})" >&2; exit 2 ;; esac
[ -n "${TEXT}" ] || { echo "capture: lesson text required" >&2; exit 2; }
if [ "${#TEXT}" -gt 2000 ]; then echo "capture: lesson too long (${#TEXT} chars > 2000; keep <=500 tokens)" >&2; exit 2; fi

WHEN="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
COMMIT="$(git -C "$(dirname "${BUFFER}")" rev-parse --short HEAD 2>/dev/null || true)"

python3 - "$BUFFER" "$TYPE" "$TEXT" "$WHEN" "$COMMIT" "$TASK" <<'PY'
import json, sys
buf, t, text, when, commit, task = sys.argv[1:7]
line = json.dumps({"type": t, "text": text, "when": when, "commit": commit,
                   "source_task": task, "tags": ["type:"+t]}, ensure_ascii=False)
with open(buf, "a", encoding="utf-8") as f:
    f.write(line + "\n")
PY
echo "capture: staged ${TYPE} lesson (${#TEXT} chars) -> ${BUFFER}"
