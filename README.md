# superpowers-memory

A Claude Code plugin: an orchestrator-mediated bridge from the superpowers subagent pipeline to
durable lessons in [Ogham](https://github.com/ogham-mcp/ogham-cli), without breaking subagent
context isolation. Design: `2026-05-29-superpowers-ogham-memory-bridge-design.md`.

## Status
v0.1 scaffold. `recall` is wired to the native `ogham` CLI; capture + distilled flush are **gated on
a positive §8.2 replay benchmark**. Private build — load with `claude --plugin-dir .`.

## Install

### 1. Get the plugin + the pinned binary
```bash
git clone https://github.com/ogham-mcp/ogham-superpowers-bridge.git
cd ogham-superpowers-bridge
./scripts/install-tools.sh            # installs the pinned .tools/ogham (SHA256-verified; macOS ad-hoc signed + de-quarantined)
./scripts/install-tools.sh --upgrade  # fetch latest, then run the replay benchmark before committing
```
You also need a configured Ogham backend (`DATABASE_URL`/Supabase + an embedding provider) — verify with
`./.tools/ogham health`. Recall is best-effort: with no backend it degrades to empty (never blocks).

### 2. Load the plugin into Claude Code
- **Dev / validation (current):** load it in-place, no marketplace needed —
  ```bash
  claude --plugin-dir /absolute/path/to/ogham-superpowers-bridge
  ```
- **Full install (post-validation):** once `.claude-plugin/marketplace.json` ships,
  `/plugin marketplace add ogham-mcp/ogham-superpowers-bridge` then
  `/plugin install superpowers-memory@<marketplace>`.

When a session starts with the plugin enabled, the SessionStart hook automatically: bootstraps the
per-repo profile `superpowers-<repo-slug>`, checks binary drift, reports any orphaned staging buffer,
and **injects the orchestrator protocol** (below) into your context.

## Using it with superpowers (the bridge in action)
The plugin does not (and cannot) edit superpowers itself. Instead, the SessionStart hook injects an
**orchestrator protocol** telling the controller how to mediate Ogham during subagent-driven work:

- **Before each subagent dispatch**, the orchestrator runs `ogham search "<task>" --profile superpowers-<slug> --limit 5`
  and folds any lessons into the curated prompt as *hints to verify, not gospel*.
- **Subagents never call Ogham** — only the orchestrator does (isolation by construction). Subagents
  receive only the curated prompt, never the hook output, so they cannot reach the bridge.
- **After ~3 tasks / at branch-finish**, the orchestrator runs `/superpowers-memory:flush`
  (v0.1: reports buffer state; the distilling scribe is gated on the §8.2 benchmark).

If you prefer to codify this per-repo instead of relying on the hook injection, copy
`templates/CLAUDE.snippet.md` into your repo's `CLAUDE.md`.

## Components
- `skills/superpowers-memory/` — `recall` (wired) + `flush` (stubbed) verbs; orchestrator-only.
- `skills/flush/` — `/superpowers-memory:flush` manual entry point.
- `hooks/` — best-effort SessionStart: profile bootstrap + binary drift check + orphan-buffer report.
- `scripts/` — hermetic binary resolver + installer.

## Tests
```bash
bash test/run.sh
```

## Invariants (do not break)
- Subagents never touch Ogham; only the orchestrator does (isolation by construction).
- CLI-via-orchestrator only — no plugin-scope MCP server.
- All Ogham access is best-effort: transport/drift errors exit 0 and degrade to empty recall.
