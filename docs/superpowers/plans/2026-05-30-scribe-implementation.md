# Scribe (write half) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the scribe — `capture.sh` (distill-at-capture) + `flush.sh` (mechanical commit, lean on Ogham's native dedup), wired into the SessionStart protocol — so the bridge learns within and across sessions.

**Architecture:** Two Bash scripts the orchestrator runs (never skill-invoked — `disable-model-invocation` blocks that, found live). Capture appends one clean ≤500-tok lesson (JSONL) to the local buffer; flush stores buffer lessons via `ogham store --source superpowers-scribe`, retaining any that fail. A shared `repo-slug.sh` gives both the hook and flush one definition of `superpowers-<slug>`. SessionStart auto-commits orphans and injects capture+flush into the orchestrator protocol.

**Tech Stack:** POSIX/bash 3.2-compatible shell + `python3` (for safe JSON in capture/flush only), the `ogham` CLI, `claude plugin validate`. Tests are dependency-free shell using a fake `ogham` via `OGHAM_BIN`.

**Spec:** `docs/superpowers/specs/2026-05-30-scribe-design.md`. Builds on the merged v0.1 scaffold (recall half, live-proven).

---

## File Structure

| Path | Responsibility |
|---|---|
| `scripts/repo-slug.sh` | Shared `repo_slug <cwd>` helper (extracted from the hook); sourced by hook + flush. |
| `scripts/capture.sh` | Append one distilled lesson (validated type + provenance) to the buffer. |
| `scripts/flush.sh` | Commit buffer lessons to Ogham; retain failures; clear successes. |
| `hooks/session-start.sh` | Source `repo-slug.sh`; auto-flush orphans; inject capture+flush protocol. |
| `skills/superpowers-memory/SKILL.md` | Real capture+flush commands (was stubbed). |
| `skills/flush/SKILL.md` | Manual `/superpowers-memory:flush` runs `flush.sh` (was report-only). |
| `skills/superpowers-memory/buffer-schema.md` | Drop "gated"; reflect scribe is built. |
| `test/test_repo_slug.sh` | Tests for the shared slug helper. |
| `test/test_capture.sh` | Tests for capture (taxonomy, provenance, length cap). |
| `test/test_flush.sh` | Tests for flush (store, retain-failures, empty). |
| `test/test_session_start.sh` | Updated: orphan auto-flush + protocol mentions capture/flush. |

---

## Task 1: Shared slug helper + refactor the hook to use it

**Files:**
- Create: `scripts/repo-slug.sh`, `test/test_repo_slug.sh`
- Modify: `hooks/session-start.sh` (replace inline `repo_slug`), `test/test_session_start.sh` (fixture copies `repo-slug.sh`)

- [ ] **Step 1: Write the failing test** — create `test/test_repo_slug.sh`:
```bash
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
```

- [ ] **Step 2: Run it — expect FAIL** (`bash test/test_repo_slug.sh`; helper missing).

- [ ] **Step 3: Create `scripts/repo-slug.sh`:**
```bash
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
```

- [ ] **Step 4: Run it — expect PASS** (`chmod +x scripts/repo-slug.sh && bash test/test_repo_slug.sh && echo OK`).

- [ ] **Step 5: Refactor the hook to source the helper.** In `hooks/session-start.sh`, replace this block:
```bash
# Per-repo profile slug: git remote basename, else cwd basename; sanitized.
# Never emits a bare "superpowers-" (which would collide across repos).
repo_slug() {
  local url base
  url="$(git -C "${CWD}" config --get remote.origin.url 2>/dev/null || true)"
  url="${url%/}"   # tolerate a trailing slash on the remote URL
  if [ -n "${url}" ]; then base="${url##*/}"; base="${base%.git}"; else base="$(basename "${CWD}")"; fi
  base="$(printf '%s' "${base}" | tr '[:upper:] ' '[:lower:]-' | tr -cd '[:alnum:]-')"
  while [ "${base#-}" != "${base}" ]; do base="${base#-}"; done   # strip leading dashes
  while [ "${base%-}" != "${base}" ]; do base="${base%-}"; done   # strip trailing dashes
  [ -n "${base}" ] || base="unknown"
  printf 'superpowers-%s' "${base}"
}
PROFILE="$(repo_slug)"
```
with:
```bash
# Per-repo profile slug (shared helper, design §4.2).
. "${ROOT}/scripts/repo-slug.sh"
PROFILE="$(repo_slug "${CWD}")"
```

- [ ] **Step 6: Update the hook test fixture to copy the new helper.** In `test/test_session_start.sh`, find:
```bash
cp "${ROOT}/scripts/ogham-bin.sh" "${fixroot}/scripts/ogham-bin.sh"
```
and add the line after it:
```bash
cp "${ROOT}/scripts/repo-slug.sh" "${fixroot}/scripts/repo-slug.sh"
```

- [ ] **Step 7: Run full suite — expect all PASS** (`bash test/run.sh`). The hook still bootstraps a `superpowers-<slug>` profile via the sourced helper.

- [ ] **Step 8: Commit**
```bash
git add scripts/repo-slug.sh test/test_repo_slug.sh hooks/session-start.sh test/test_session_start.sh
git commit -m "refactor: extract shared repo-slug helper; hook sources it (scribe prep)"
```

---

## Task 2: `scripts/capture.sh` — distill-at-capture

**Files:**
- Create: `scripts/capture.sh`, `test/test_capture.sh`

- [ ] **Step 1: Write the failing test** — create `test/test_capture.sh`:
```bash
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
```

- [ ] **Step 2: Run it — expect FAIL** (`bash test/test_capture.sh`; capture missing).

- [ ] **Step 3: Create `scripts/capture.sh`:**
```bash
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
```

- [ ] **Step 4: Run it — expect PASS** (`chmod +x scripts/capture.sh && bash test/test_capture.sh && echo OK`).

- [ ] **Step 5: Commit**
```bash
git add scripts/capture.sh test/test_capture.sh
git commit -m "feat: capture.sh — distill-at-capture staging (taxonomy + provenance)"
```

---

## Task 3: `scripts/flush.sh` — commit, retain failures

**Files:**
- Create: `scripts/flush.sh`, `test/test_flush.sh`

- [ ] **Step 1: Write the failing test** — create `test/test_flush.sh`:
```bash
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
```

- [ ] **Step 2: Run it — expect FAIL** (`bash test/test_flush.sh`; flush missing).

- [ ] **Step 3: Create `scripts/flush.sh`:**
```bash
#!/usr/bin/env bash
# Commit staged lessons to Ogham (scribe spec). Best-effort; retains lines whose store fails so
# nothing is lost; Ogham's native surprise/auto-link dedups. Run by the orchestrator (N=3 +
# branch-finish) and by the SessionStart hook for orphans.
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
    tags = "type:%s,commit:%s,task:%s" % (d.get("type",""), d.get("commit",""), d.get("source_task",""))
    r = subprocess.run([ogham, "store", d.get("text",""), "--profile", profile,
                        "--source", "superpowers-scribe", "--tags", tags],
                       capture_output=True, text=True)
    if r.returncode == 0:
        flushed += 1
    else:
        failed += 1; kept.append(ln)
with open(buf, "w", encoding="utf-8") as f:
    if kept:
        f.write("\n".join(kept) + "\n")
print("flush: flushed %d, retained %d (failed), profile %s" % (flushed, failed, profile))
PY
exit 0
```

- [ ] **Step 4: Run it — expect PASS** (`chmod +x scripts/flush.sh && bash test/test_flush.sh && echo OK`).

- [ ] **Step 5: Commit**
```bash
git add scripts/flush.sh test/test_flush.sh
git commit -m "feat: flush.sh — commit lessons to Ogham, retain failures, lean on native dedup"
```

---

## Task 4: Wire the scribe into the SessionStart hook

**Files:**
- Modify: `hooks/session-start.sh` (orphan auto-flush + protocol), `test/test_session_start.sh`

- [ ] **Step 1: Update the hook test for the new behavior.** In `test/test_session_start.sh`:

(a) Extend the fake `ogham` to record `store` — replace:
```bash
if [ "$1" = "version" ]; then printf '{"version": "%s"}\n' "${FAKE_VERSION:-0.7.3}"; exit 0; fi
exit 0
```
with:
```bash
if [ "$1" = "version" ]; then printf '{"version": "%s"}\n' "${FAKE_VERSION:-0.7.3}"; exit 0; fi
if [ "$1" = "store" ]; then echo "store $*" >> "${OGHAM_CALLS}"; exit 0; fi
exit 0
```

(b) Replace the case-4 block:
```bash
# 4. Orphan-buffer report when buffer is non-empty
echo '{"type":"decision","text":"x"}' > "${work}/.superpowers-lessons.jsonl"
orphan="$(printf '{"cwd":"%s"}' "$work" | OGHAM_BIN="$fake" FAKE_VERSION=0.7.3 OGHAM_CALLS="${work}/c4" bash "$HOOK" 2>&1)"
echo "$orphan" | grep -qi 'orphan' || { echo "  orphan: expected orphaned-buffer report"; rc=1; }
```
with (orphan is now AUTO-FLUSHED, then the buffer is cleared):
```bash
# 4. Orphan buffer is auto-flushed (committed) at SessionStart, then cleared.
buf4="${work}/.superpowers-lessons.jsonl"
printf '%s\n' '{"type":"decision","text":"orphan lesson","when":"t","commit":"abc","source_task":"t1","tags":["type:decision"]}' > "$buf4"
c4="${work}/c4"; : > "$c4"
orphan="$(printf '{"cwd":"%s"}' "$work" | OGHAM_BIN="$fake" FAKE_VERSION=0.7.3 OGHAM_CALLS="$c4" bash "$HOOK" 2>&1)"
grep -q '^store ' "$c4" || { echo "  orphan: expected auto-flush store call"; rc=1; }
[ -s "$buf4" ] && { echo "  orphan: expected buffer cleared after flush"; rc=1; }
```

(c) Replace the case-5 protocol assertions:
```bash
echo "$proto" | grep -q 'search' || { echo "  protocol: expected the recall (search) command"; rc=1; }
echo "$proto" | grep -qiE 'subagents? must never' || { echo "  protocol: expected the subagent-isolation rule"; rc=1; }
```
with (protocol now also names capture + flush):
```bash
echo "$proto" | grep -q 'search' || { echo "  protocol: expected the recall (search) command"; rc=1; }
echo "$proto" | grep -q 'capture.sh' || { echo "  protocol: expected the capture command"; rc=1; }
echo "$proto" | grep -q 'flush.sh' || { echo "  protocol: expected the flush command"; rc=1; }
echo "$proto" | grep -qiE 'subagents? must never' || { echo "  protocol: expected the subagent-isolation rule"; rc=1; }
```
Note: case 5 runs with `work` as cwd and a leftover buffer from case 4 is cleared, so case 5's buffer is empty — fine.

- [ ] **Step 2: Run the hook test — expect FAIL** (`bash test/test_session_start.sh`; hook not yet updated).

- [ ] **Step 3: Update `hooks/session-start.sh` orphan block.** Replace:
```bash
# 3. orphan-buffer report (distilled flush is gated on the §8.2 benchmark -- v0.1 only reports)
BUFFER="${CWD}/.superpowers-lessons.jsonl"
if [ -s "${BUFFER}" ]; then
  n="$(wc -l < "${BUFFER}" | tr -d ' ')"
  echo "superpowers-memory: orphaned staging buffer (${n} candidates) -- run /superpowers-memory:flush to distill."
fi
```
with:
```bash
# 3. orphan recovery: auto-commit a crash-orphaned buffer. Lines are pre-distilled (distill-at-
#    capture), so this is a mechanical store -- safe to run at startup. Best-effort.
BUFFER="${CWD}/.superpowers-lessons.jsonl"
if [ -s "${BUFFER}" ]; then
  n="$(wc -l < "${BUFFER}" | tr -d ' ')"
  echo "superpowers-memory: recovering orphaned staging buffer (${n} candidate(s))..."
  SUPERPOWERS_BUFFER="${BUFFER}" SUPERPOWERS_PROFILE="${PROFILE}" bash "${ROOT}/scripts/flush.sh" 2>&1 || true
fi
```

- [ ] **Step 4: Update the injected protocol.** In the `cat <<EOF` block, replace the final bullet:
```bash
- AFTER ~3 tasks and at branch-finish, run the flush (v0.1 reports buffer state; the distilling scribe is gated on the §8.2 benchmark):
    /superpowers-memory:flush
```
with:
```bash
- AFTER each task's two-stage review, IF it surfaced signal (a reviewer caught something / implementer hit BLOCKED then resolved / a decision was made / a finding recurred), capture one clean <=500-token lesson:
    "${ROOT}/scripts/capture.sh" --type <workflow-lesson|recurring-mistake|decision|tooling-fact|review-pattern> --task "<task-id>" "<the lesson>"
- AFTER every 3 captures and at branch-finish, commit them to Ogham:
    "${ROOT}/scripts/flush.sh"
```

- [ ] **Step 5: Run full suite — expect all PASS** (`bash test/run.sh`).

- [ ] **Step 6: Restore the real pinned version if a test touched it, and confirm** (`printf '0.7.3\n' > .tools/.version`).

- [ ] **Step 7: Commit**
```bash
git add hooks/session-start.sh test/test_session_start.sh
git commit -m "feat: SessionStart auto-flushes orphans + injects capture/flush protocol"
```

---

## Task 5: Update the skills + buffer schema to the real scribe

**Files:**
- Modify: `skills/superpowers-memory/SKILL.md`, `skills/flush/SKILL.md`, `skills/superpowers-memory/buffer-schema.md`

- [ ] **Step 1: Replace the stubbed flush section in `skills/superpowers-memory/SKILL.md`.** Replace the entire `## Verb: \`flush\` (STUBBED — gated on the §8.2 benchmark)` section (from that heading through the closing code fence and the `See \`buffer-schema.md\`…` line) with:
````markdown
## Verbs: `capture` + `flush` (WIRED)

Both run as Bash scripts you (the orchestrator) invoke — never via the Skill tool (the skills are
`disable-model-invocation`). Resolve the plugin root once: it is `${CLAUDE_PLUGIN_ROOT}`.

**Capture (distill-at-capture).** After a task's two-stage review, **only if it surfaced signal** — a
reviewer caught something, the implementer hit BLOCKED then resolved it, a decision was made, or a
finding recurred — write one clean ≤500-token lesson:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/capture.sh" \
  --type <workflow-lesson|recurring-mistake|decision|tooling-fact|review-pattern> \
  --task "<task-id>" "<the distilled lesson>"
```
Clean tasks write nothing. `capture.sh` validates the type against the §5 taxonomy, stamps provenance
(`when`, `commit`, `source_task`), and appends one JSONL line to `./.superpowers-lessons.jsonl`.

**Flush (commit).** After every 3 captures and at branch-finish, commit the buffer to Ogham:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/flush.sh"
```
`flush.sh` stores each staged lesson with `--source superpowers-scribe` into `superpowers-<repo-slug>`,
relying on Ogham's native surprise/auto-link to dedup. Lines that fail to store are retained for the
next flush (nothing is lost); successes are cleared. Best-effort — never blocks.

See `buffer-schema.md` for the candidate format and the §5 taxonomy.
````

- [ ] **Step 2: Replace the body of `skills/flush/SKILL.md`** (keep the frontmatter unchanged). Replace everything from `# /superpowers-memory:flush` to the end of the file with:
````markdown
# /superpowers-memory:flush

Manual trigger for the bridge flush — a defensive safety valve (e.g. just before closing a branch)
when you want to commit staged lessons without waiting for the automatic N=3 / branch-finish cadence.

It runs the same script the orchestrator uses:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/flush.sh"
```
This stores each staged lesson into `superpowers-<repo-slug>` with `--source superpowers-scribe`
(Ogham's native surprise/auto-link dedups), retains any that fail, and clears successes. Best-effort.
If the buffer is empty it reports "nothing to flush".
````

- [ ] **Step 3: Update `skills/superpowers-memory/buffer-schema.md`.** Replace:
```markdown
Distilled flush into Ogham is **gated on the §8.2 replay benchmark** — until then this file only
accumulates candidates; the SessionStart hook reports orphans.
```
with:
```markdown
Lessons are written here by `scripts/capture.sh` (distill-at-capture) and committed to Ogham by
`scripts/flush.sh` (every 3 captures + branch-finish). The SessionStart hook auto-commits any orphan.
```

- [ ] **Step 4: Validate the plugin** (`claude plugin validate . 2>&1 || echo unavailable`) — passes; both skills still discovered.

- [ ] **Step 5: Commit**
```bash
git add skills/superpowers-memory/SKILL.md skills/flush/SKILL.md skills/superpowers-memory/buffer-schema.md
git commit -m "docs: skills + buffer-schema reflect the wired scribe (capture/flush)"
```

---

## Task 6: End-to-end — the compounding loop, live

**Files:**
- Modify: `README.md` (Status line)

- [ ] **Step 1: Full suite + plugin validate**
```bash
bash test/run.sh && echo ALL-GREEN
claude plugin validate . 2>&1 | tail -2
```
Expected: 6 test files PASS (`test_ogham_bin`, `test_install_tools`, `test_repo_slug`, `test_capture`, `test_flush`, `test_session_start`), `ALL-GREEN`, validation passes.

- [ ] **Step 2: Live capture→flush→recall loop in a throwaway profile** (proves the compounding loop, then cleans up):
```bash
OG=./.tools/ogham
PREV="$($OG profile current 2>/dev/null | sed -n 's/.*"profile"[^"]*"\([^"]*\)".*/\1/p')"
work="$(mktemp -d)"; ( cd "$work" && git init -q )
NONCE="loop-$(date +%s)"
# capture a lesson (as the orchestrator would, after a task)
SUPERPOWERS_BUFFER="$work/.superpowers-lessons.jsonl" \
  ./scripts/capture.sh --type tooling-fact --task demo "${NONCE}: flush+recall loop proof"
# flush it into a throwaway profile
SUPERPOWERS_BUFFER="$work/.superpowers-lessons.jsonl" SUPERPOWERS_PROFILE="superpowers-loop-demo" \
  ./scripts/flush.sh
# recall it back (the read half) from that profile
echo "--- recall ---"
$OG search "$NONCE flush recall loop" --profile superpowers-loop-demo --limit 3 2>/dev/null \
  | python3 -c "import sys,json;d=json.load(sys.stdin);rs=d if isinstance(d,list) else d.get('results',[]);print('hit:', any('$NONCE' in (r.get('content') or '') for r in rs))"
# cleanup: delete the seeded memory + restore profile
mid="$($OG search "$NONCE" --profile superpowers-loop-demo --limit 1 2>/dev/null | python3 -c "import sys,json;d=json.load(sys.stdin);rs=d if isinstance(d,list) else d.get('results',[]);print(rs[0]['id'] if rs else '')")"
[ -n "$mid" ] && $OG delete "$mid" --profile superpowers-loop-demo -y >/dev/null 2>&1
[ -n "$PREV" ] && $OG profile switch "$PREV" >/dev/null 2>&1
rm -rf "$work"
$OG profile current
```
Expected: `hit: True` (a lesson captured then flushed is recalled back), then the active profile restored. This is the intra-session compounding loop end-to-end.

- [ ] **Step 3: Update the README Status line.** Replace:
```markdown
v0.1 scaffold. `recall` is wired to the native `ogham` CLI; capture + distilled flush are **gated on
a positive §8.2 replay benchmark**. Private build — load with `claude --plugin-dir .`.
```
with:
```markdown
v0.2. Both halves wired: `recall` (read) and the **scribe** — `capture` (distill-at-capture) + `flush`
(commit, leaning on Ogham's native dedup). The §8.2 replay benchmark remains available to decide
whether to *operate* the bridge at a given cadence. Private build — load with `claude --plugin-dir .`.
```

- [ ] **Step 4: Commit**
```bash
git add README.md
git commit -m "docs: README status — scribe wired (v0.2)"
```

- [ ] **Step 5: Push**
```bash
git push origin main
```

---

## Phase 3 (not in this plan)
- Auto-detect "signal" mechanically (vs orchestrator judgment) — only if the prompt-level gate proves unreliable.
- The §8.2 replay benchmark + measurement harness — to decide whether to *operate* long-term (user-set threshold + corpus).
- `marketplace.json` publish (Council Q6) after 2–3 clean real sessions.
