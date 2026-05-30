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
OGHAM="$("${CLAUDE_PLUGIN_ROOT:-$PWD}/scripts/ogham-bin.sh")" || {
  echo "superpowers-memory: no ogham binary; recall unavailable (graceful degradation)."; exit 0; }
```

If resolution fails, **degrade gracefully** — continue with empty recall, never block a dispatch
(design §6).

## Verb: `recall` (WIRED)

Before dispatching a subagent, recall lessons scoped to the current task and fold the result into the
**curated prompt** you are about to send (do NOT edit files on disk; do NOT let the subagent call
this skill). Use the active per-repo profile (bootstrapped by the SessionStart hook).

```bash
# Relevance-ranked top-K lessons for this task. `ogham search` takes a POSITIONAL query
# (not --query) and runs native hybrid (vector + keyword) search against the active profile.
# JSON output by default; sub-100ms native Go path (design §9).
"$OGHAM" search "<short description of the task you are about to dispatch>" --limit 5 2>/dev/null || true

# Optional: a cached wiki-preamble at a chosen resolution — this is the §4.3 `wiki_preamble_level`
# knob (one_line / short / body). Phase 2 tunes the level by budget; not required for v0.1 recall.
# "$OGHAM" recall topic-summary "<topic>" 2>/dev/null || true
```

> Note: `ogham search` needs `DATABASE_URL` + `EMBEDDING_PROVIDER` + the provider key configured. If
> they aren't, the command fails and the `|| true` degrades to empty recall (design §6) — never block.

Fold the returned lessons into the dispatch prompt as **hints to verify, not gospel**, each stamped
with its `(when, commit, source-task)` provenance. Budget: keep total recall injection per dispatch
to roughly 1500 tokens; prefer short preambles, and when many lessons return, summarize rather than
paste. If recall returns nothing relevant, inject a single line: *"No proven lesson exists for this
task shape yet"* and consider widening the subagent's exploration budget.

## Verb: `flush` (STUBBED — gated on the §8.2 benchmark)

Capture and distilled flush are **not implemented in v0.1**. The interface is fixed so Phase 2 only
fills in the body:

- **Capture** (future): after a task's two-stage review passes AND it surfaced signal (a reviewer
  caught something / implementer hit BLOCKED then resolved / a decision was made / a finding
  repeated), append one typed candidate to `./.superpowers-lessons.jsonl` per `buffer-schema.md`.
  Clean tasks write nothing.
- **Flush** (future, every N=3 candidates + at branch-finish): a scribe reads the buffer, dedupes/
  merges against existing repo memories, distills survivors (<=500 tokens each), and writes them with
  `source="superpowers-scribe"`, tags, and TTL, then clears the buffer.

Until the benchmark proves positive, `flush` only reports the buffer state:

```bash
BUFFER="${PWD}/.superpowers-lessons.jsonl"
if [ -s "$BUFFER" ]; then
  echo "superpowers-memory: $(wc -l < "$BUFFER" | tr -d ' ') candidate(s) staged. Distilled flush is gated on the §8.2 replay benchmark (not yet enabled)."
else
  echo "superpowers-memory: staging buffer empty."
fi
```

See `buffer-schema.md` for the candidate format and the §5 taxonomy that bounds what may ever be stored.
