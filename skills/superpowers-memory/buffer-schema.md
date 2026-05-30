# Staging buffer: `.superpowers-lessons.jsonl`

Crash-safe local capture in the worktree (design §4.2). Gitignored (see `.gitignore` at the repo root). One JSON object per line.
Lessons are written here by `scripts/capture.sh` (distill-at-capture) and committed to Ogham by
`scripts/flush.sh` (every 3 captures + branch-finish). The SessionStart hook auto-commits any orphan.

Each line:
```json
{"type":"workflow-lesson","text":"<the lesson, <=500 tokens>","when":"<ISO-8601>","commit":"<git sha>","source_task":"<task id or label>","tags":["..."]}
```

`type` is one of the five allowed taxonomy values (design §5), nothing else:
`workflow-lesson` · `recurring-mistake` · `decision` · `tooling-fact` · `review-pattern`.

Hard-excluded (never write these): raw code/snippets, transient task context, inter-agent messages.
