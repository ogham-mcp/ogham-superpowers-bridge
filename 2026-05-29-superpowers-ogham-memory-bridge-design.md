# Design: `superpowers-memory` — an Ogham bridge for the superpowers subagent pipeline

- **Date:** 2026-05-29
- **Status:** Draft (design approved in brainstorming; not yet planned/implemented)
- **Author:** Kevin Burns (with design-council deliberation)
- **Topic:** Let the superpowers plugin reuse durable lessons via Ogham without breaking subagent context isolation.

> ⚠️ This file is a portable record of a brainstorming session so it can be re-iterated inside a
> proper git repo. The working directory it was authored in (`~/Developer/Projects`) is not a git
> repo, so it was written but not committed. Move it into the target repo and commit there.

---

## 1. Problem statement

When running superpowers subagent-driven development, subagents are slow because they:

- **(A) Re-read long stretches of code** every dispatch (re-explore the same codebase).
- **(B) Re-derive lessons / repeat mistakes** the system has already learned from.

The original idea was to create a shared Ogham memory profile (`superpower`) and let subagents
**intercommunicate / share freely** through it.

## 2. Council verdict (why the literal idea is the wrong topology)

The superpowers subagent model is built on **deliberate context isolation**. From
`subagent-driven-development`:

> "Fresh subagent per task (no context pollution)... They should never inherit your session's
> context or history — you construct exactly what they need... Controller curates exactly what
> context is needed."

| Idea | Judgment |
|---|---|
| Subagents *freely read/write & intercommunicate* via a shared profile | ❌ **Bad** — fights the isolation invariant; causes context pollution, memory poisoning (lesson from project A misapplied to project B), stale code, and non-determinism (subagent behaviour depends on mutable shared state). "Intercommunication" is an explicit subagent anti-pattern. |
| Use Ogham so superpowers *stops repeating mistakes & re-deriving lessons* | ✅ **Good** — but via **orchestrator-mediated retrieval**, not a back-channel between workers. |

**Conclusion: good problem, wrong topology.** Keep the goal, flip the data flow — Ogham becomes a
*retrieval source for the curator (orchestrator)*, never a *channel between workers*.

Note: problems (A) and (B) have different right answers. (A) re-reading code is a caching/curation
concern where Ogham is the *wrong* tool (code drifts from HEAD). (B) re-deriving lessons is exactly
what Ogham is for (durable, low-drift, high-signal process knowledge). **This design addresses (B)
only.**

## 3. Decisions locked in brainstorming

| # | Decision | Choice |
|---|---|---|
| 1 | Direction | **Orchestrator-mediated bridge** (not a literal shared-comms store) |
| 2 | Scope | **Per-repo profile** (`superpowers-<repo-slug>`) |
| 3 | Integration | **Companion skill + hooks** (in user's own `~/.claude`, survives plugin updates; no fork) |
| 4 | Write model | **Staged capture → distilled flush** (decouple capture from commit) |
| 5 | Flush cadence | **Every N tasks (N=3) + always at branch-finish** |

### Why companion-skill-not-fork
The superpowers plugin lives in `~/.claude/plugins/cache/claude-plugins-official/superpowers/5.1.0/`.
Anything edited inside it is **wiped on the next plugin update**. The bridge therefore lives entirely
in the user's own `~/.claude` and is a pure consumer of the `ogham` CLI — no upstream fork to
maintain, no edits to plugin-owned files.

## 4. Architecture

### 4.1 Topology (non-negotiable invariant)
Ogham is a **retrieval source for the orchestrator**, never a channel between subagents. Subagents
stay fully isolated and never touch Ogham. All reads and writes flow through the orchestrator (or a
dedicated **scribe** subagent it dispatches).

### 4.2 Components

1. **Companion skill** `superpowers-memory` in `~/.claude/skills/`. Exposes two verbs the
   orchestrator calls: `recall` and `flush`. Survives plugin updates.
2. **Per-repo Ogham profile** `superpowers-<repo-slug>`. Strong isolation against cross-project
   poisoning; clean provenance. **The smart-inscribe hooks (PR #43, v0.13.1) are disabled for this
   profile** — the scribe is the only writer. Smart-inscribe captures raw action traces, which §5
   hard-excludes; running both writers against the same profile would violate the taxonomy. Profile
   is created eagerly on the SessionStart hook (`ogham profile switch <name>` with auto-create) so
   the orphan-flush always has a valid target on first run.
3. **Staging buffer** `./.superpowers-lessons.jsonl` in the worktree — crash-safe local capture.
   Added to `.gitignore`.
4. **SessionStart hook** — on startup, if a non-empty staging buffer exists (orphaned by a crash),
   flush it before doing anything else.

### 4.3 Data flow

**Read — dispatch-time recall:**
Before dispatching each subagent, the orchestrator runs `recall` scoped to `(repo, task, skill)` via
the fast native `ogham recall` path → takes top-K → folds provenance-stamped lessons into the
**curated prompt** (appended to the existing `implementer-prompt.md` / reviewer prompts at dispatch
time, NOT by editing files on disk). Each injected lesson carries `(when, commit, source-task)` and
is framed as *"a hint to verify, not gospel."*

- **Recall resolution & budget.** Request lessons at `wiki_preamble_level="short"` (~150-300
  tok/lesson, v0.13) by default; downgrade to `"one_line"` (~30-50 tok) when K>5. Hard cap ~1500
  tok of total recall injection per dispatch so the orchestrator's curation budget stays bounded.
- **`gap_note` as signal.** When `hybrid_search` returns `gap_note != null` (stale, low-confidence,
  or contradicted result set — v0.14), the orchestrator injects a "no proven lesson exists for this
  task shape yet" line in place of stale lessons, and considers raising the implementer's
  exploration budget for that subagent. Treats absence-of-lesson as actionable, not silent.

**Write — staged capture → distilled flush:**

- **Capture (per task, signal-gated):** after a task's two-stage review passes, append a raw
  candidate to the buffer **only if** the task surfaced signal:
  - a reviewer (spec or quality) caught something, or
  - the implementer hit `BLOCKED` then resolved it, or
  - a decision was made, or
  - a finding repeated.

  Clean tasks write nothing. This signal-gate is what eliminates per-task noise. Buffer writes are
  near-free and crash-safe (on disk in the worktree).

- **Flush (every N=3 candidates + always at branch-finish):** the scribe reads the buffer →
  dedupes/merges against existing repo memories → distills survivors into durable lessons → writes
  them with tags + TTL → clears the buffer.

### 4.4 Why this is the write-side sweet spot
Decoupling **capture** (cheap, frequent, signal-gated, local) from **commit-to-memory** (distilled,
batched, deduped, to Ogham) gives:

- **Nothing is lost** — buffer is on disk; SessionStart hook flushes any orphan after a crash.
- **Mid-branch recall works** — after any flush, later tasks recall earlier tasks' lessons.
- **Ogham only ever receives distilled, deduped, high-signal writes** — the quality gate lives in
  the flush, not the capture.
- Avoids both failure modes of the naive options: the all-or-nothing risk of branch-finish-only, and
  the noise/dedup burden of write-every-task.

## 5. Lesson taxonomy (the only things allowed in)

Allowed memory types:

- `workflow-lesson` — e.g. "test runner is X; common gotcha is Y"
- `recurring-mistake` (+ its correction)
- `decision` — ADR-style, dated, with the *why*
- `tooling-fact` — build/lint commands, where things live
- `review-pattern` — recurring code-review findings for this repo

**Hard-excluded:** raw code/snippets (drift), transient task context (belongs in the curated
prompt), inter-agent messages (orchestrator's job).

## 6. Guardrails

- Per-repo profile scope.
- Fixed taxonomy (above).
- TTL + Hebbian decay so unused lessons fade (Ogham natively supports both).
- Provenance on every memory (`when`, `commit`, `source-task`).
- Dedup/merge at flush.
- Idempotent writes (avoid bloat).
- Every recalled memory is presented to the orchestrator as a *hint to verify*, not authority.
- All scribe writes use `source="superpowers-scribe"` so audits filter cleanly:
  `ogham show_audit_log --source=superpowers-scribe` (v0.13.1) is the forensic entry point.
- Distilled lessons capped at ~500 tokens each. Bounds the recall budget tax and stops one bad
  flush from writing a 10k-token wall of distilled prose.
- **Graceful degradation.** Transport errors from `ogham recall` / `ogham store` (Postgres
  unreachable, sidecar process down) → orchestrator continues with empty recall; scribe flushes
  accumulate in the local JSONL buffer; the SessionStart hook retries them on the next run. Hard
  exit only on client-side bugs (4xx, type errors). Pattern borrowed verbatim from claude-mem's
  transport-error-exit-0 hook discipline (§12 prior art) — a flaky Postgres must never block a
  subagent dispatch.

## 7. Out of scope (YAGNI)

- Solving code re-reading (problem A) — different concern; not this bridge.
- Subagent-to-subagent messaging — explicitly rejected by the council.
- Modifying or forking Ogham — pure CLI consumer.
- Cross-project / global memory — rejected in favour of per-repo scope.

## 8. Evaluation — prove the mechanism before building the infra

Net value depends on **signal-to-noise**, and the production feedback loop is slow (real
superpowers dev runs at a monthly-or-longer cadence). The discipline is therefore: **decouple
evaluation from organic cadence — prove the mechanism cheaply by replay before committing to
build.**

### 8.1 Two value streams (do not conflate them)

- **Intra-session (cross-task) recall** — within *one* orchestration run, task N recalls what tasks
  1..N-1 learned (after a flush). **Cadence-independent**: pays off inside a single monthly session,
  because each run dispatches many subagents back-to-back. A static file cannot serve this (it is
  written by humans *between* sessions). This is the bulk of the early, provable value.
- **Inter-session (cross-month) recall** — across runs. **Cadence-gated and back-loaded**; real but
  slow to accrue, and subject to a cold-start ramp on the very first session for a repo.

### 8.2 Replay benchmark (collapses months → an afternoon)

Build a fixed corpus of ~15–25 representative subagent tasks pulled from existing transcripts. The
concrete paths to mine: `.in_use/` under the project root for in-flight sessions;
`~/.claude/projects/<project-slug>/agent-*.jsonl` for subagent traces;
`~/.claude/projects/<project-slug>/*.jsonl` for parent-session transcripts. Pre-seed the per-repo profile with the lessons those sessions
would have produced. Run each task **twice back-to-back — recall-on vs recall-off** — same model,
same prompt. Per task, measure: exploration tool calls (Read/Grep/Glob/Bash), input+output tokens,
wall-clock, and **quality** (did the two-stage review pass first try?). Explicitly include the
intra-session case: *does task 6 avoid re-exploring what task 2's lesson already captured?*

### 8.3 Leading indicators (faster + less noisy than "time saved")

- **Recall hit-rate** — at dispatch, does the query return a *relevant* lesson? If ~0, the bridge
  cannot be helping → kill early.
- **Redundant-exploration rate** — fraction of subagent file-reads that re-fetch what a recalled
  lesson already stated.
- **Repeat-mistake rate** — does the same reviewer finding recur across tasks? Cleanest *causal*
  signal: capture lesson for mistake X → mistake X should stop recurring.

### 8.4 Break-even model (go/no-go given cadence)

Cost = build hours + per-session overhead (recall latency + flush/dedup tokens). Savings =
(intra-session exploration avoided, every run) + (inter-session exploration avoided × hit-rate ×
sessions/month). If months-to-break-even is large *and* intra-session savings are weak, defer the
build. A positive replay result proves the mechanism works, not that it is worth operating at this
cadence — judge both.

## 8a. Why not a hand-curated CLAUDE.md / lessons file?

A static file is a **different, weaker primitive**, not a cheaper version of the store:

| Limitation | CLAUDE.md / static file | Ogham store |
|---|---|---|
| Loading model | Whole file, always, into every context — unconditional, unranked tax that grows and dilutes attention | Top-K **retrieved by relevance** — bounded injection |
| Addressability | Same blob to everyone | Per-task recall into a *specific* subagent's curated prompt |
| Capture | Human must remember, place, dedupe — lossy at any cadence | Automated scribe; nothing forgotten |
| Freshness | Lessons rot silently | TTL + Hebbian decay fade stale lessons |
| Structure | Prose; provenance lost | Structured, `(when, commit, source-task)` stamped |
| Access mode | Read-only document | Director can **query fast + write durable mid-flight** |

The decisive row is the last: the orchestrator/director is an *active* agent that must query at
dispatch and write at flush — fast, on disk, durable, **within a single run**. A markdown file
cannot. Ogham's sub-100ms native `recall` + `store` is exactly that primitive. CLAUDE.md remains
useful for stable, always-relevant project facts — not for dynamic, per-task, auto-captured lessons.

## 8b. Relationship to caveman (orthogonal, not an alternative)

`caveman` (github.com/JuliusBrussee/caveman) is **output-token compression** — terse "caveman" prose
that cuts ~15–75% of *output* tokens with zero state, full value on session #1. It attacks a
different cost axis than this bridge:

| Axis | caveman | Ogham bridge |
|---|---|---|
| Cuts | Output tokens (~4× expensive) — narration | Re-derivation: repeated mistakes + wasted *exploration* (input tokens) |
| State | None | Per-repo memory that accumulates |
| Value on session #1 | Full | Intra-session once buffer fills; inter-session back-loaded |
| Cadence sensitivity | None | Intra-session none; inter-session high |
| Adoption effort | One file | Skill + hooks + scribe + dedup |

They are complementary — **adopt caveman regardless**; it neither stops repeated mistakes nor reduces
code re-reading, and the bridge does not compress narration.

## 9. Relevant Ogham CLI surface (verified 2026-05-29)

- `ogham recall` — read-only recall verbs, sub-100ms cold-start (native Go path). **This perf
  envelope is load-bearing for the design.** The MCP server path (`ogham serve`) requires Python
  runtime initialisation + transport handshake per session, typically hundreds of ms to single-digit
  seconds before the first call returns. For per-dispatch recall on every subagent in a long
  orchestration (dozens of dispatches per session), only the native CLI path is fast enough to call
  inline without dragging out wall-clock. This — together with the isolation argument in §10 — is
  why CLI-via-orchestrator beats MCP-in-plugin even before any subagent-isolation guard is bolted
  on.
- `ogham search` — hybrid search across stored memories.
- `ogham store` — store a memory in the active profile.
- `ogham profile {current,list,switch,ttl}` — per-profile management; TTL in days.
- `ogham decay` — apply Hebbian decay to stale memories.
- `ogham cleanup` — remove expired memories.
- `ogham export` / `import` — JSON/Markdown.
- `--sidecar`/`--python` — full retrieval pipeline (intent detection, strided retrieval, query
  reformulation, MMR, graph augmentation) when richer recall is worth the latency.
- Default output is JSON (LLM/script friendly); `--text` for humans.

Existing assets that already do half of this: the user's `save-learnings` skill and a SessionStart
hook that loads memories. The bridge formalizes that loop *for the subagent pipeline specifically*.

## 10. Packaging — plugin vs loose files (open for next brainstorm)

**A Claude Code plugin is not "chained skills."** It is a manifest-driven *distribution container*
bundling several component types under one `.claude-plugin/plugin.json`. Skills are one component.

Component slots a plugin can carry (verified against the installed `superpowers/5.1.0` plugin):

| Component | What it is | superpowers uses it? |
|---|---|---|
| `skills/` | SKILL.md capabilities | ✅ |
| `hooks/hooks.json` | lifecycle hooks (SessionStart, PreToolUse, …) | ✅ (`SessionStart`) |
| `commands/` | slash commands | — (slot available) |
| `agents/` | subagent definitions | — (slot available) |
| `.mcp.json` | MCP servers to auto-connect | — (slot available) |

A plugin adds: manifest + versioning, `${CLAUDE_PLUGIN_ROOT}` path portability, one-step install,
and marketplace publishing.

### The bridge is a textbook plugin
It is exactly the multi-component case where a plugin (not loose files) is the right wrapper:

1. **skill** → `superpowers-memory` (`recall`/`flush` verbs)
2. **hook** → SessionStart orphan-flush
3. **command** (optional) → `/ogham-flush`, `/ogham-eval` for manual control
4. **MCP server** (optional) → Ogham already ships one (`ogham serve`); a plugin can declare it in
   `.mcp.json` so recall/store become native MCP tools instead of Bash shell-outs.

Decision #3 ("companion skill + hooks in `~/.claude`") is *functionally a plugin without the
packaging*. Wrapping it as a proper plugin is strictly better **if** we want to version/share/install
it; loose `~/.claude` files are simpler for a private one-off. Components are identical either way —
so this is a **distribution decision, not an architecture one.**

### ⚠️ Caveat — the MCP route fights the isolation invariant
If Ogham is bundled **as an MCP server** at plugin scope, `recall`/`store` become available to
**every agent, including subagents** — directly contradicting the load-bearing rule that *subagents
never touch Ogham; only the orchestrator does.* A subagent could call `ogham_recall` itself and
reintroduce the context pollution the design exists to prevent.

- **CLI-via-orchestrator** (current design) → tighter; only the orchestrator's Bash steps call
  `ogham`; subagents structurally can't; keeps the fast native Go path (§9).
- **MCP-server-in-plugin (unguarded)** → cleaner ergonomics, but "subagents don't call it" must be
  re-enforced at the prompt/discipline level since the tools are globally exposed.
- **MCP-server-in-plugin + per-agent tool allowlists** → a third option worth flagging. A Claude
  Code plugin's `agents/` slot lets each subagent definition declare its allowed tools; the
  orchestrator agent gets `ogham_*`, the implementer/reviewer agents do not. Isolation enforced by
  construction (not prompt discipline) — but the MCP startup tax (§9) still applies on every
  dispatch and the recall call goes through the slower Python path. Cleaner than option 2; still
  loses on perf vs CLI. **Not preferred** given the §9 cold-start argument.

**Tentative position (revisit next round):** package as a plugin (skill + hook + optional commands),
but keep Ogham access as the CLI invoked by the orchestrator — do **not** auto-wire the MCP server
at plugin scope. CLI wins on **both** axes that matter: (a) isolation by construction (subagents
structurally can't shell out to the orchestrator's Bash), and (b) sub-100ms native Go cold-start vs
the MCP server's Python initialisation tax (§9), which compounds across the dozens of dispatches in
a long orchestration. Distributable + versioned, with the isolation invariant *and* the perf
envelope both enforced by construction.

**To decide next brainstorm:** plugin vs loose files (distribution need?) · whether `/`-commands are
worth shipping · whether a guarded MCP-server option is worth the ergonomics vs the isolation risk.

## 11. Next steps

1. Move this spec into a proper git repo and commit.
2. Re-review / iterate on the design in that repo.
3. **Adopt `caveman` immediately** — orthogonal, free, validates in one session (§8b).
4. **Run the replay benchmark (§8.2) on existing transcripts *before building the bridge*.** Get a
   real recall hit-rate + redundant-exploration number, focused on the intra-session case. Let that
   data decide go/no-go.
5. **If the mechanism proves out**, proceed to an implementation plan (superpowers `writing-plans`),
   covering: the `superpowers-memory` skill (`recall`/`flush` verbs), the staging buffer format +
   `.gitignore` entry, the SessionStart orphan-flush hook, the per-repo profile naming/bootstrap, the
   scribe distillation prompt, and the measurement harness from §8.

Open carry-over for round two also includes the substrate question (§12) and the
**beads-for-tasks + Ogham-for-lessons composable-layers** idea.

## 12. Alternatives considered: storage substrates

The substrate decision turns on **what data** is stored and **who writes it concurrently**. Three
distinct jobs are routinely conflated; this design needs only the second.

| Job | Best-fit substrate | Needed here? |
|---|---|---|
| Task/work DAG (deps, status, "what's unblocked") | **beads** — genuinely excellent | ❌ out of scope (§7); superpowers has plans/TodoWrite |
| **Durable lessons, recalled by relevance** | **Ogham** — semantic/vector top-K, decay, MMR | ✅ the whole point |
| Human knowledge garden | Obsidian / markdown / QMD | ❌ not our use case |

### Candidates evaluated

- **beads (`bd`, Steve Yegge — github.com/gastownhall/beads / steveyegge/beads).** Go; git-backed
  JSONL source of truth + SQLite cache (some variants use Dolt, a version-controlled SQL DB).
  Single-writer file locking in embedded mode; server mode allows concurrent writers; hash-based IDs
  (`bd-a1b2`) avoid merge collisions. Core strength is a **dependency-aware task DAG**
  (epics/tasks/subtasks; `relates_to`/`duplicates`/`supersedes`; `bd ready`).
  - *Now markets itself as memory:* added `bd remember "insight"`; README says *"persistent,
    structured memory for coding agents... do not create MEMORY.md files."*
  - *Decisive gap:* **no semantic/vector retrieval** — keyword/structured filtering only. Cannot
    relevance-rank "lessons relevant to *this* task," which is exactly our recall need.
  - *Verdict:* its crown jewel (task DAG) is the dimension we excluded; its overlapping feature
    (`bd remember`) is its weakest, retrieval-wise. Wrong layer for the lessons job.

- **Obsidian graph / markdown / QMD (query-over-markdown).** File-based; manual human linking
  (Obsidian) or lexical search (QMD/grep). Merge-conflict-prone under concurrent writes, no
  transactional consistency, no relevance ranking. Fine for single-human knowledge gardening; poor
  for concurrent multi-agent data work. Ruled out.

- **Ogham.** Postgres/Supabase + embedder; native sub-100ms Go recall path; semantic top-K, TTL +
  Hebbian decay, MMR, provenance. Higher infra cost in general — but ~zero for this author, who
  builds and runs it. Best fit for relevance-ranked lessons recall.

### The design twist that settles it

Our topology **serializes all writes through the orchestrator/scribe (single writer) with a local
JSONL staging buffer.** This *designs away* the multi-agent write-concurrency problem — so the
substrate must be judged on **read-side retrieval quality**, not write concurrency. On retrieval:
Ogham (semantic) > beads (`bd remember`, keyword) > markdown/QMD (lexical). Ogham wins for the
lessons job.

### Carry-over idea (not a decision)

beads and the Ogham bridge are **different layers, not competitors**: beads = the cross-session task
DAG; Ogham bridge = the lessons. A future superpowers setup could run **both** — beads for plan/task
tracking, the Ogham bridge for lessons — composed in different parts of the pipeline. Out of scope
for this spec; flagged for round two.

### Prior art — claude-mem (added 2026-05-30)

`claude-mem` (Alex Newman / @thedotmack, Apache 2.0, **79,306 GitHub stars verified via `gh api`
2026-05-28**, repo created 2025-08-31) ships the same broad pattern this bridge proposes —
lifecycle-hook capture + per-session worker + retrieval injection into agent context — but
optimised for *single-developer Claude Code usage*. Differences worth naming explicitly so this
design isn't read as a copy:

| Axis | claude-mem | this bridge |
|---|---|---|
| Unit captured | Raw per-tool action traces (`PostToolUse` observations) | Distilled durable lessons (one of §5's five types) |
| Capture cadence | Every tool call, automatic | Signal-gated per task; flushed every N=3 + branch-finish |
| Retrieval reach | Direct from session (orchestrator + subagents) | Orchestrator-mediated only; subagents structurally never touch the store |
| Storage stack | Bun worker + SQLite + ChromaDB + Claude Agent SDK (purpose-built) | `ogham` CLI consumer (existing infra, no new daemon) |
| Concurrency model | Multi-process worker | Single-writer scribe + JSONL staging buffer |
| Scope | Per-user, single machine | Per-repo profile |
| Failure on infra outage | Hook exits 0 on transport error | Same pattern (borrowed verbatim — §6 guardrails) |

Strategic note: claude-mem's `docs/ip-boundary.md` reserves team/org sync, RBAC, audit-log UI, and
hosted cloud as commercial — same wedges the Ogham four-doors strategy targets — but ships none of
them in OSS today. The bridge is therefore a deliberate variant of a *widely-validated* pattern (79k
stars in ~9 months), not a from-scratch experiment, and stays in a slot claude-mem has explicitly
reserved for its commercial roadmap. Defends against reviewer pushback ("isn't this just
claude-mem?") and credits prior art. Full intel: Ogham memory `f9d2af21-496b-4b29-95c9-15f9e61de84f`.

## 13. Installation isolation — hermetic `ogham` binary

§9's CLI-first choice raises a binary-resolution problem the rest of the spec doesn't address. On
the author's R&D machine there are **two distinct binaries both named `ogham`**:

1. **`ogham-mcp` (Python)** — the editable dev install in the R&D repo's `.venv/bin/ogham`.
   Schema-current, frequently breaking, ships the `ogham serve` MCP server.
2. **`ogham-cli` (Go)** — the released native binary at `~/go/bin/ogham` or `/usr/local/bin/ogham`.
   This is the load-bearing CLI from §9 (sub-100ms cold-start).

If the bridge orchestrator shells out to bare `ogham` and `$PATH` happens to surface the Python
venv copy (because the developer is in the R&D shell, or because the venv is activated), the bridge
runs schema-current dev Ogham against the bridge profile and can write data the released CLI can't
read back. The bridge MUST resolve to a *pinned released* `ogham-cli` Go binary, not whatever
`command -v ogham` happens to return.

### 13.1 Hermetic layout

```
ogham-superpower-bridge/
  .tools/
    ogham           # pinned ogham-cli Go binary (e.g. v0.7.0), gitignored
    .version        # "0.7.0" — checked at SessionStart
  scripts/
    install-tools.sh  # fetches pinned binary from ogham-cli GitHub releases
  .gitignore        # ignores .tools/ogham
```

### 13.2 Resolution order (bridge skill internals)

```bash
OGHAM_BIN="${OGHAM_BIN:-${CLAUDE_PLUGIN_ROOT:-$PWD}/.tools/ogham}"
[ -x "$OGHAM_BIN" ] || OGHAM_BIN="$(command -v ogham)" || die "no ogham binary"
"$OGHAM_BIN" recall ...
```

- Default path: the pinned `.tools/ogham`, fully hermetic.
- Escape hatch: `OGHAM_BIN=$(which ogham) ogham-superpowers-recall ...` for one-off dev experiments.
- Last-resort PATH fallback only if neither is set — fails loud if nothing is installed.

### 13.3 SessionStart binary check

The SessionStart hook (already needed for orphan-flush — §4.2 component 4) also asserts the binary
matches `.tools/.version` and offers `scripts/install-tools.sh --upgrade` if drift is detected.
Mirrors claude-mem's Setup hook that ensures Bun + uv are present before its worker starts (§12
prior art) — same install-discipline pattern, different runtime.

### 13.4 Upgrade contract

When `ogham-cli` ships a new release, the bridge does **not** auto-upgrade. The developer runs
`./scripts/install-tools.sh --upgrade`, bumps `.tools/.version`, runs the replay benchmark (§8.2) to
catch any regression, then commits. For a future public plugin, the Setup hook auto-fetches at
install time based on `plugin.json`'s declared version — pinned at the manifest, not at HEAD of the
ogham-cli repo.

### 13.5 Why not Homebrew / system-wide install for the bridge

A `brew install ogham-cli` global install works for ad-hoc dev use, but breaks the bridge's
reproducibility contract: `brew upgrade` can silently move the binary under a running orchestration,
and CI environments don't have brew. The hermetic `.tools/` layout is the same pattern Node uses for
`node_modules/` and Python uses for `.venv/` — applied to a binary dependency.
