# Scribe (write half) — design spec

- **Date:** 2026-05-30
- **Status:** Approved in brainstorming; ready for implementation plan.
- **Scope:** The capture + flush "scribe" that lets the bridge *learn* — the write half deferred as
  gated Phase 2 in the v0.1 scaffold (Council Q5). Builds on the merged, live-proven recall half.
- **Refines:** the main design `2026-05-29-…-design.md` §4.3/§4.4 — distillation moves **from flush to
  capture** (see "Decisions"). All other invariants (§4.1 isolation, §5 taxonomy, §6 guardrails) hold.

## Why now
The live run (2026-05-30, `docs/live-validation-2026-05-30.md`) proved recall end-to-end but exposed
two things: (1) no intra-session learning exists without the scribe; (2) `disable-model-invocation`
means the **orchestrator cannot invoke the flush skill** — only a human can. The scribe must therefore
be **Bash the orchestrator runs**, like recall already is.

## Decisions (locked in brainstorming)
| # | Decision | Choice |
|---|---|---|
| 1 | Invocation model | **Bash scripts the orchestrator runs** (`capture.sh`, `flush.sh`). Skills stay `disable-model-invocation` as human/manual entries + docs. No reliance on model-invoking a skill. |
| 2 | Distillation location | **At capture** — the orchestrator writes a clean ≤500-tok lesson while context is fresh; flush is a mechanical commit. (Refines §4.3's "distilled flush": the quality gate moves to capture; §4.4 goals still hold.) |
| 3 | Dedup/merge | **Lean on Ogham's native `store` pipeline** (extraction → embed+search → surprise → auto-link). No custom dedup in flush. |
| 4 | Flush cadence | **Every N=3 captures + at branch-finish** (orchestrator-driven, per injected protocol). |
| 5 | Orphan recovery | SessionStart **auto-commits** an orphaned buffer (mechanical store; safe because lines are pre-distilled), replacing v0.1's report-only. Best-effort, exit 0. |

## Components
1. `scripts/repo-slug.sh` — **shared** slug helper. Extract `repo_slug()` out of `hooks/session-start.sh`
   into a sourceable file; the hook and `flush.sh` both source it (DRY; one definition of `superpowers-<slug>`).
2. `scripts/capture.sh` — append one distilled lesson to the buffer.
3. `scripts/flush.sh` — commit buffer lessons to Ogham; retain any that fail.
4. `hooks/session-start.sh` — source `repo-slug.sh`; extend the injected protocol (capture+flush
   instructions); auto-flush orphans via `flush.sh`.
5. `skills/flush/SKILL.md` + `skills/superpowers-memory/SKILL.md` — manual/doc paths now run `flush.sh`
   (skills remain `disable-model-invocation`; humans can still `/superpowers-memory:flush`).

## Capture — `scripts/capture.sh`
Interface (run by the orchestrator after a task's two-stage review, only if signal surfaced):
```
capture.sh --type <taxonomy> --task "<task-id>" "<the lesson text>"
```
- **Signal gate (orchestrator's judgment, §4.3):** capture only when a reviewer caught something, the
  implementer hit BLOCKED then resolved, a decision was made, or a finding recurred. Clean tasks → no call.
- `--type` must be one of the §5 taxonomy values: `workflow-lesson | recurring-mistake | decision |
  tooling-fact | review-pattern`. Reject (exit non-zero, message) otherwise — the taxonomy gate.
- Stamps provenance: `when` (ISO-8601 UTC), `commit` (`git -C <cwd> rev-parse --short HEAD`, or `""`),
  `source_task` (`--task`).
- Appends exactly one JSONL line to `./.superpowers-lessons.jsonl` matching `buffer-schema.md`:
  `{"type","text","when","commit","source_task","tags":["type:<t>"]}`.
- Uses `python3` to emit valid JSON (safe escaping of arbitrary lesson text). Best-effort: a failure
  prints a notice and exits non-zero, but never throws away the orchestrator's intent.
- Caps text at ~500 tokens-worth (~2000 chars) defensively; over-long input is rejected with a hint.

## Flush — `scripts/flush.sh`
Run by the orchestrator every 3 captures + at branch-finish (and by the SessionStart hook for orphans).
- Resolve binary via `scripts/ogham-bin.sh`; resolve profile via `scripts/repo-slug.sh`. If the binary
  is unresolved, print a notice and exit 0 (degrade; buffer untouched).
- If buffer absent/empty → print "nothing to flush", exit 0.
- For each JSONL line (parsed with `python3`):
  `"$OGHAM" store "<text>" --profile "superpowers-<slug>" --source superpowers-scribe --tags "type:<t>,commit:<sha>,task:<label>"`
- **Partial-failure safety:** rewrite the buffer to contain only the lines whose `store` failed
  (transient backend errors) — successfully-stored lines are dropped. Nothing is lost; failures retry
  next flush. Ogham's native surprise/auto-link dedups re-stored or near-duplicate lessons.
- Print a one-line summary: `flushed N, retained M (failed), cleared buffer`.
- Best-effort throughout; never exits non-zero in a way that could block a SessionStart hook.

## SessionStart protocol update (`hooks/session-start.sh`)
- Source `scripts/repo-slug.sh` (replacing the inline `repo_slug`).
- **Orphan recovery:** if the buffer is non-empty at startup, run `flush.sh` (auto-commit), then report
  what happened — instead of v0.1's report-only.
- **Injected protocol** gains capture + flush lines (the *how*, still not lessons), e.g.:
  - "After each task's two-stage review, **if** signal surfaced, run:
    `\"<plugin>\"/scripts/capture.sh --type <…> --task \"<id>\" \"<lesson>\"`."
  - "After every 3 captures and at branch-finish, run: `\"<plugin>\"/scripts/flush.sh`."
  - Recall line unchanged.

## Skills
- `skills/flush/SKILL.md` — the manual `/superpowers-memory:flush` now invokes `flush.sh` (real flush),
  still `disable-model-invocation` (human entry point).
- `skills/superpowers-memory/SKILL.md` — replace the stubbed flush prose with the real capture+flush
  commands (pointing at the scripts); recall section unchanged.

## Guardrails (unchanged — §6)
`source=superpowers-scribe` on every write; ≤500 tok/lesson; taxonomy enforced at capture; provenance
in tags (`commit:`, `task:`); idempotency via Ogham surprise; TTL via profile; **everything
best-effort** — capture/flush failures degrade gracefully and never block a dispatch or the session.

## Runtime dependency
`capture.sh` and `flush.sh` use `python3` for safe JSON emit/parse (present on macOS and the target).
The resolver, installer, and hook stay pure POSIX/bash. Noted so the plan can add a `python3` presence
check (degrade gracefully if absent).

## Testing (dependency-free shell, fake `ogham` via `OGHAM_BIN`)
- `capture.sh`: rejects an out-of-taxonomy type; appends a valid JSONL line with `type/when/commit/
  source_task`; over-long text rejected.
- `flush.sh`: stores each buffer line (asserts the fake received `store … --source superpowers-scribe`);
  retains lines whose store failed; clears successes; empty-buffer case prints "nothing to flush".
- `hooks/session-start.sh`: orphan buffer is auto-committed (fake receives stores) then buffer cleared;
  protocol output now contains the capture+flush instructions; still always exits 0.
- `scripts/repo-slug.sh`: same slug behavior the hook test already asserts (no bare/colliding slug).

## Relationship to the §8.2 benchmark
Building the scribe **crosses the Q5 gate** (chosen as Option A: build it, see the compounding loop).
The §8.2 replay benchmark remains available afterward to decide whether to *operate* the bridge
long-term at the user's cadence — proving the mechanism (done live) ≠ proving it's worth operating.

## Success criteria
Re-running the live demo with the scribe built: a task that surfaces signal → `capture.sh` writes a
lesson → `flush.sh` (at N=3 / branch-finish) commits it to `superpowers-<slug>` → a **later** task's
recall returns that lesson. The intra-session compounding loop (§8.1), observed live.
