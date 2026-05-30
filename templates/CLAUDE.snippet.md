<!--
Optional: paste this block into your repo's CLAUDE.md to codify the superpowers-memory bridge
protocol per-repo, instead of (or in addition to) relying on the plugin's SessionStart hook
injection. The orchestrator reads CLAUDE.md; subagents receive only curated prompts, so the
isolation invariant is preserved either way.
-->

## superpowers-memory bridge — orchestrator protocol

This repo uses the `superpowers-memory` plugin to reuse durable lessons from Ogham during
subagent-driven work. **You (the orchestrator/controller) mediate Ogham. Subagents must NEVER call
`ogham` or this bridge — only you do** (isolation invariant).

- **Before each subagent dispatch**, recall task-relevant lessons (best-effort; on empty/error just
  proceed) and fold any results into the curated subagent prompt as *"hints to verify, not gospel"*
  with their provenance:
  ```bash
  OGHAM="$("${CLAUDE_PLUGIN_ROOT:-$PWD}/scripts/ogham-bin.sh")" && \
    "$OGHAM" search "<short description of the task you are about to dispatch>" \
      --profile "superpowers-<repo-slug>" --limit 5
  ```
- **After ~3 tasks and at branch-finish**, run `/superpowers-memory:flush` (v0.1 reports buffer
  state; the distilling scribe is gated on the §8.2 benchmark).
