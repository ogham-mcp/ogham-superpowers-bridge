#!/usr/bin/env bash
# Commit staged lessons to Ogham (scribe spec). Best-effort; retains lines whose store fails so
# nothing is lost; Ogham's native surprise/auto-link dedups. Run by the orchestrator (N=3 +
# branch-finish) and by the SessionStart hook for orphans.
# Note: if killed mid-flush, already-stored lines may be re-stored on the next run; Ogham's native
# surprise/auto-link makes that an idempotent no-op (empty commit:/task: tag values are accepted).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUFFER="${SUPERPOWERS_BUFFER:-$PWD/.superpowers-lessons.jsonl}"

OGHAM="$(bash "${SCRIPT_DIR}/ogham-bin.sh" 2>/dev/null || true)"
if [ -z "${OGHAM}" ]; then echo "flush: no ogham binary; buffer left intact (degraded)."; exit 0; fi

if [ -n "${SUPERPOWERS_PROFILE:-}" ]; then
  PROFILE="${SUPERPOWERS_PROFILE}"
else
  . "${SCRIPT_DIR}/repo-slug.sh"
  PROFILE="$(repo_slug "$(dirname "${BUFFER}")")"
fi

if [ ! -s "${BUFFER}" ]; then echo "flush: staging buffer empty -- nothing to flush."; exit 0; fi

python3 - "$OGHAM" "$PROFILE" "$BUFFER" <<'PY'
import json, subprocess, sys
ogham, profile, buf = sys.argv[1:4]
with open(buf, encoding="utf-8") as f:
    lines = [ln for ln in f.read().splitlines() if ln.strip()]
kept, flushed, failed = [], 0, 0
for ln in lines:
    try:
        d = json.loads(ln)
    except Exception:
        continue  # drop a corrupt line (capture always writes valid JSON)
    text = (d.get("text") or "").strip()
    if not text:
        continue  # skip empty-text lines (nothing useful to store)
    tags = "type:%s,commit:%s,task:%s" % (d.get("type",""), d.get("commit",""), d.get("source_task",""))
    r = subprocess.run([ogham, "store", text, "--profile", profile,
                        "--source", "superpowers-scribe", "--tags", tags],
                       capture_output=True, text=True)
    if r.returncode == 0:
        flushed += 1
    else:
        failed += 1; kept.append(ln)
        if r.stderr.strip():
            print("flush: store failed: %s" % r.stderr.strip()[:200], file=sys.stderr)
with open(buf, "w", encoding="utf-8") as f:
    if kept:
        f.write("\n".join(kept) + "\n")
print("flush: flushed %d, retained %d (failed), profile %s" % (flushed, failed, profile))
PY
exit 0
