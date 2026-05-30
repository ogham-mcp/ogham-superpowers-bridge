# Staging buffer: `.superpowers-lessons.jsonl`

Crash-safe local capture in the worktree (design §4.2). Gitignored. One JSON object per line.
Distilled flush into Ogham is **gated on the §8.2 replay benchmark** — until then this file only
accumulates candidates; the SessionStart hook reports orphans.

Each line:
```json
{"type":"workflow-lesson","text":"<the lesson, <=500 tokens>","when":"<ISO-8601>","commit":"<git sha>","source_task":"<task id or label>","tags":["..."]}
```

`type` is one of the five allowed taxonomy values (design §5), nothing else:
`workflow-lesson` · `recurring-mistake` · `decision` · `tooling-fact` · `review-pattern`.

Hard-excluded (never write these): raw code/snippets, transient task context, inter-agent messages.
