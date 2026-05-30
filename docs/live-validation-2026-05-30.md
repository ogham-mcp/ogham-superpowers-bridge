# Live validation — 2026-05-30

First end-to-end run of the `superpowers-memory` bridge inside a **real superpowers session**, observed live.

## Setup
- Plugin loaded via `claude --plugin-dir /Users/kevinburns/Developer/ogham-superpower-bridge`.
- Test repo: `~/Developer/ogham-bridge-demo` (separate from the plugin repo → its own per-repo profile).
- Task: build a static product landing page for the Ogham Bridge (`TASK.md`) — a multi-step build
  (index.html → styles.css → README) well suited to superpowers' brainstorm → plan → subagent flow.
- Profile `superpowers-ogham-bridge-demo` pre-seeded with 4 lessons (the **recall-only** path; the
  write-side scribe is gated — see below). Backend: Supabase + Gemini, healthy.

## What was proven (the recall half) ✅
1. **SessionStart injects the orchestrator protocol** (round-3 integration trigger, §14.8a) into the
   controller's context — the bridge self-wires with no edit to superpowers.
2. **Recall before every dispatch.** The orchestrator ran, ahead of all three implementer dispatches:
   ```
   "…/ogham-superpower-bridge/.tools/ogham" search "<task-specific query>" \
     --profile "superpowers-ogham-bridge-demo" --limit 5
   ```
   with fresh, task-shaped queries (e.g. *"build static accessible dark-theme landing page semantic
   HTML CSS"*, *"CSS dark theme tokens responsive grid WCAG contrast focus styles"*, *"README how to
   open static landing page no build step"*).
3. **Correct hermetic binary** — the pinned `.tools/ogham`, resolved under `--plugin-dir`, not a PATH copy.
4. **Isolated per-repo profile** — all recall scoped to `superpowers-ogham-bridge-demo`, distinct from
   `work` (2339 memories) / `personal`.
5. **Lessons folded as hints-to-verify** — the orchestrator returned the seeded lessons and stated it
   would "fold these into the implementer prompt as hints-to-verify with their provenance" (verbatim §4.3).
6. **Orchestrator-mediated** — recall ran as the controller's Bash steps; subagents did not call Ogham.

## What is NOT yet proven (the write half) ❌ — gated
- **Capture** (signal-gated append to `.superpowers-lessons.jsonl`) and **distilled flush** (dedupe/
  merge → `ogham store` with provenance/TTL) are not implemented in v0.1 (Q5, gated on the §8.2 benchmark).
- **Observed consequence:** nothing was written during the run, so round 2's recall returned only the
  **pre-seeded** lessons — never anything round 1 produced. This is exactly the **intra-session value
  stream (§8.1)** the scribe is responsible for, and it is the headline value case still to build.

## Verdict
The bridge does **half its job, reliably**: recall is live-proven across a full multi-task superpowers
build, with isolation and the hermetic binary both holding. The compounding loop (task N learns →
task N+1 recalls it) requires the scribe (capture + flush) — the next build.

## Disposable test artifacts
- Profile `superpowers-ogham-bridge-demo` (4 seeded memories) and `~/Developer/ogham-bridge-demo`.
- The live session switches the global active profile; restore with `ogham profile switch work`.
