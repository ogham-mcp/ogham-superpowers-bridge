---
name: flush
description: Manually flush the superpowers-memory staging buffer. Orchestrator-only defensive safety valve before branch close; independent of the automatic N=3 / branch-finish cadence. Surfaced as /superpowers-memory:flush.
disable-model-invocation: true
---

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
