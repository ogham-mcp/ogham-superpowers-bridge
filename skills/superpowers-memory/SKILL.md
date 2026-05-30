---
name: superpowers-memory
description: Orchestrator-only bridge to Ogham durable lessons for the superpowers subagent pipeline. Use ONLY from the orchestrator/controller (never a subagent) to recall per-task lessons before dispatch and to flush captured lessons. Exposes two verbs - recall and flush.
disable-model-invocation: true
---

# superpowers-memory

A bridge so the **orchestrator** (and only the orchestrator) can reuse durable lessons from Ogham
without breaking subagent context isolation. Subagents must never invoke this skill or the `ogham`
binary — that is the load-bearing invariant (design §4.1). All reads/writes flow through the
orchestrator or a scribe it dispatches.

## Resolve the binary first (always)

Every Bash step below resolves the pinned binary via the shared resolver (design §13.2):

```bash
OGHAM="$("${CLAUDE_PLUGIN_ROOT:-$PWD}/scripts/ogham-bin.sh")" || OGHAM=""
[ -n "$OGHAM" ] || echo "superpowers-memory: no ogham binary; recall unavailable (graceful degradation)."
```

If resolution fails, **degrade gracefully**: `OGHAM` is empty, so guard every `ogham` call with
`[ -n "$OGHAM" ]` and simply skip recall — never `exit`, never block a dispatch (design §6).

## Verb: `recall` (WIRED)

Before dispatching a subagent, recall lessons scoped to the current task and fold the result into the
**curated prompt** you are about to send (do NOT edit files on disk; do NOT let the subagent call
this skill). Use the active per-repo profile (bootstrapped by the SessionStart hook).

```bash
# Relevance-ranked top-K lessons for this task. `ogham search` takes a POSITIONAL query
# (not --query) and runs native hybrid (vector + keyword) search against the active profile.
# JSON output by default; sub-100ms native Go path (design §9).
if [ -n "$OGHAM" ]; then
  "$OGHAM" search "<short description of the task you are about to dispatch>" --limit 5 2>/dev/null || true
fi

# Optional: a cached wiki-preamble at a chosen resolution. The design's §4.3 `wiki_preamble_level`
# maps to the CLI `--level` flag (one_line ~30-50 tok / short ~150-300 tok / body ~1000 words;
# default body). Phase 2 tunes the level by budget; not required for v0.1 recall.
# "$OGHAM" recall topic-summary "<topic>" --level short 2>/dev/null || true
```

> Note: `ogham search` needs `DATABASE_URL` + `EMBEDDING_PROVIDER` + the provider key configured. If
> they aren't, the command fails and the `|| true` degrades to empty recall (design §6) — never block.

Fold the returned lessons into the dispatch prompt as **hints to verify, not gospel**, each stamped
with its `(when, commit, source-task)` provenance. Budget: keep total recall injection per dispatch
to roughly 1500 tokens; prefer short preambles, and when many lessons return, summarize rather than
paste. If recall returns nothing relevant, inject a single line: *"No proven lesson exists for this
task shape yet"* and consider widening the subagent's exploration budget.

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
