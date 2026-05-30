---
name: flush
description: Manually flush the superpowers-memory staging buffer. Orchestrator-only defensive safety valve before branch close; independent of the automatic N=3 / branch-finish cadence. Surfaced as /superpowers-memory:flush.
disable-model-invocation: true
---

# /superpowers-memory:flush

Manual trigger for the `flush` verb of the `superpowers-memory` skill. Use this as a defensive safety
valve (e.g. just before closing a branch) when you want to flush staged lessons without waiting for
the automatic cadence.

In v0.1 the distilled flush is **gated on the §8.2 replay benchmark**, so this reports the staging
buffer state rather than writing to Ogham:

```bash
BUFFER="${PWD}/.superpowers-lessons.jsonl"
if [ -s "$BUFFER" ]; then
  echo "superpowers-memory: $(wc -l < "$BUFFER" | tr -d ' ') candidate(s) staged. Distilled flush is gated on the §8.2 replay benchmark (not yet enabled)."
else
  echo "superpowers-memory: staging buffer empty — nothing to flush."
fi
```

When the benchmark proves positive, this delegates to the `superpowers-memory` skill's real scribe
flush (dedupe/merge/distill, `source="superpowers-scribe"`, TTL).
