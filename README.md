# superpowers-memory

A Claude Code plugin: an orchestrator-mediated bridge from the superpowers subagent pipeline to
durable lessons in [Ogham](https://github.com/ogham-mcp/ogham-cli), without breaking subagent
context isolation. Design: `2026-05-29-superpowers-ogham-memory-bridge-design.md`.

## Status
v0.1 scaffold. `recall` is wired to the native `ogham` CLI; capture + distilled flush are **gated on
a positive §8.2 replay benchmark**. Private build — load with `claude --plugin-dir .`.

## Install the pinned binary
```bash
./scripts/install-tools.sh            # installs the pinned .tools/.version
./scripts/install-tools.sh --upgrade  # fetch latest, then run the replay benchmark before committing
```
The binary is verified by SHA256 and, on macOS, ad-hoc signed + de-quarantined.

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
