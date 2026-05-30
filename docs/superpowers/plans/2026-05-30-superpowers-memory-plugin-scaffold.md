# superpowers-memory Plugin Scaffold — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the ungated v0.1 scaffold of the `superpowers-memory` Claude Code plugin — a hermetic install path, the plugin manifest, a best-effort SessionStart hook, and two skills (recall wired, scribe stubbed) — so the §8.2 replay benchmark can run against it.

**Architecture:** A Claude Code plugin loaded via `--plugin-dir` during validation. The orchestrator (only) invokes a pinned native-Go `ogham` binary in `.tools/` via Bash steps inside a single skill (`recall` + `flush` verbs). Subagents never touch Ogham — isolation by construction. A SessionStart hook bootstraps the per-repo profile, checks binary drift, and reports orphaned staging buffers. All Ogham access is best-effort: any transport/drift error exits 0 and degrades to empty recall.

**Tech Stack:** POSIX/bash 3.2-compatible shell, JSON manifests, Markdown SKILL files, the `ogham` CLI (v0.7.3), `claude plugin validate`. Tests are dependency-free shell scripts under `test/`.

**Scope boundary:** This plan implements Council steps 1–5 (ungated). The scribe distillation prompt, capture signal-gate, flush dedup/merge, recall-injection real logic, and the §8 measurement harness are **gated on a positive replay benchmark** and listed in "Phase 2 (gated)" at the end — do not implement them in this plan.

**Design references:** `2026-05-29-superpowers-ogham-memory-bridge-design.md` §4 (data flow), §5 (taxonomy), §6 (guardrails), §13 (hermetic install), §14 (locked round-2 decisions).

---

## File Structure

| Path | Responsibility |
|---|---|
| `.gitignore` | Ignore the pinned binary + staging buffer; keep provenance files tracked. |
| `scripts/ogham-bin.sh` | Single source of truth for binary resolution (§13.2 / §14.3 order). Sourced by the hook; documented for the skill. |
| `scripts/install-tools.sh` | Hermetic installer: pin, download, SHA256-verify, macOS sign/unquarantine, `install` + `--upgrade`. |
| `.claude-plugin/plugin.json` | Plugin manifest (`name: superpowers-memory`, version omitted → git SHA during validation). |
| `hooks/hooks.json` | Declares the SessionStart hook, pointing at the script via `${CLAUDE_PLUGIN_ROOT}`. |
| `hooks/session-start.sh` | Best-effort SessionStart logic: profile bootstrap + drift check + orphan-buffer report. Always exits 0. |
| `skills/superpowers-memory/SKILL.md` | The orchestrator-facing skill: `recall` (wired) + `flush` (stubbed) verbs, resolution boilerplate. |
| `skills/superpowers-memory/buffer-schema.md` | The `.superpowers-lessons.jsonl` staging-buffer contract (§5 taxonomy). |
| `skills/flush/SKILL.md` | Thin manual entry point surfaced as `/superpowers-memory:flush`. |
| `test/test_ogham_bin.sh` | Tests for the resolver. |
| `test/test_install_tools.sh` | Tests for installer pure functions (no network). |
| `test/test_session_start.sh` | Tests for the hook using a fake `ogham` stub via `OGHAM_BIN`. |
| `test/run.sh` | Runs all `test/test_*.sh`, non-zero on any failure. |

---

## Task 1: `.gitignore` + provenance contract

**Files:**
- Create: `.gitignore`

- [ ] **Step 1: Write `.gitignore`**

```gitignore
# Pinned ogham binary — hermetic, never committed (design §13.1). Provenance files stay tracked.
.tools/ogham
# Crash-safe local staging buffer (design §4.2) — never committed.
.superpowers-lessons.jsonl
# macOS noise
.DS_Store
```

- [ ] **Step 2: Verify the binary is ignored but provenance files are tracked**

Run:
```bash
git check-ignore .tools/ogham .superpowers-lessons.jsonl && \
git check-ignore .tools/.version .tools/LICENSE 2>/dev/null; echo "version/license ignored? exit=$?"
```
Expected: first command prints `.tools/ogham` and `.superpowers-lessons.jsonl`; the second prints nothing and reports `exit=1` (i.e. `.version` and `LICENSE` are NOT ignored).

- [ ] **Step 3: Commit**

```bash
git add .gitignore
git commit -m "build: gitignore pinned binary + staging buffer"
```

---

## Task 2: Binary resolver `scripts/ogham-bin.sh`

**Files:**
- Create: `scripts/ogham-bin.sh`
- Test: `test/test_ogham_bin.sh`, `test/run.sh`

- [ ] **Step 1: Write the test runner**

Create `test/run.sh`:
```bash
#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail=0
for t in "${DIR}"/test_*.sh; do
  echo "=== ${t##*/} ==="
  if bash "$t"; then echo "PASS: ${t##*/}"; else echo "FAIL: ${t##*/}"; fail=1; fi
done
exit "$fail"
```

- [ ] **Step 2: Write the failing test**

Create `test/test_ogham_bin.sh`:
```bash
#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${DIR}/.." && pwd)"
RESOLVER="${ROOT}/scripts/ogham-bin.sh"
rc=0

# 1. OGHAM_BIN override wins when executable
tmp="$(mktemp)"; chmod +x "$tmp"
got="$(OGHAM_BIN="$tmp" CLAUDE_PLUGIN_ROOT=/nonexistent bash "$RESOLVER" 2>/dev/null)"
[ "$got" = "$tmp" ] || { echo "  override: expected $tmp got '$got'"; rc=1; }
rm -f "$tmp"

# 2. Falls back to CLAUDE_PLUGIN_ROOT/.tools/ogham
got="$(unset OGHAM_BIN; CLAUDE_PLUGIN_ROOT="$ROOT" bash "$RESOLVER" 2>/dev/null)"
[ "$got" = "${ROOT}/.tools/ogham" ] || { echo "  plugin-root: expected ${ROOT}/.tools/ogham got '$got'"; rc=1; }

# 3. Loud-fail when nothing resolvable
if (unset OGHAM_BIN; PATH=/nonexistent CLAUDE_PLUGIN_ROOT=/nonexistent CLAUDE_PLUGIN_DATA=/nonexistent bash "$RESOLVER" >/dev/null 2>&1); then
  echo "  loud-fail: expected non-zero exit"; rc=1
fi
exit "$rc"
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `bash test/test_ogham_bin.sh`
Expected: FAIL (resolver does not exist yet; errors / non-zero).

- [ ] **Step 4: Write `scripts/ogham-bin.sh`**

```bash
#!/usr/bin/env bash
# Resolve the pinned ogham binary (design §13.2 / §14.3).
# Prints the absolute path on stdout; exits 1 with a stderr message if none found.
# Resolution order: $OGHAM_BIN -> ${CLAUDE_PLUGIN_ROOT:-$PWD}/.tools/ogham
#                   -> ${CLAUDE_PLUGIN_DATA}/bin/ogham -> command -v ogham (loud-fail)
set -uo pipefail

resolve_ogham_bin() {
  if [ -n "${OGHAM_BIN:-}" ] && [ -x "${OGHAM_BIN}" ]; then
    printf '%s\n' "${OGHAM_BIN}"; return 0
  fi
  local root="${CLAUDE_PLUGIN_ROOT:-$PWD}"
  if [ -x "${root}/.tools/ogham" ]; then
    printf '%s\n' "${root}/.tools/ogham"; return 0
  fi
  if [ -n "${CLAUDE_PLUGIN_DATA:-}" ] && [ -x "${CLAUDE_PLUGIN_DATA}/bin/ogham" ]; then
    printf '%s\n' "${CLAUDE_PLUGIN_DATA}/bin/ogham"; return 0
  fi
  if command -v ogham >/dev/null 2>&1; then
    command -v ogham; return 0
  fi
  echo "ogham-bin: no ogham binary found (set OGHAM_BIN or run scripts/install-tools.sh)" >&2
  return 1
}

# Executed directly -> print path. Sourced -> only define the function.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  resolve_ogham_bin
fi
```

- [ ] **Step 5: Make executable and run the test to verify it passes**

Run: `chmod +x scripts/ogham-bin.sh && bash test/test_ogham_bin.sh && echo OK`
Expected: prints `OK` (exit 0, no failure lines).

- [ ] **Step 6: Commit**

```bash
git add scripts/ogham-bin.sh test/test_ogham_bin.sh test/run.sh
git commit -m "feat: hermetic ogham binary resolver (§13.2)"
```

---

## Task 3: Hermetic installer `scripts/install-tools.sh`

**Files:**
- Create: `scripts/install-tools.sh`
- Test: `test/test_install_tools.sh`

- [ ] **Step 1: Write the failing test (pure functions, no network)**

Create `test/test_install_tools.sh`:
```bash
#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${DIR}/.." && pwd)"
# Source the installer WITHOUT running main() (guarded by BASH_SOURCE check).
# shellcheck disable=SC1090
source "${ROOT}/scripts/install-tools.sh"
rc=0

# detect_asset returns a non-empty .tar.gz for this platform
asset="$(detect_asset)"
case "$asset" in
  ogham-cli-*-*.tar.gz) : ;;
  *) echo "  detect_asset: unexpected '$asset'"; rc=1 ;;
esac

# sha256_of matches a known value for a known input
tmp="$(mktemp)"; printf 'hello' > "$tmp"
# echo -n 'hello' | shasum -a 256 -> 2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824
got="$(sha256_of "$tmp")"
[ "$got" = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824" ] \
  || { echo "  sha256_of: got '$got'"; rc=1; }
rm -f "$tmp"

# verify_checksum: matching passes, mismatch fails
ck="$(mktemp)"
printf '%s  %s\n' "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824" "blob.tar.gz" > "$ck"
blob="$(mktemp)"; printf 'hello' > "$blob"
if ! verify_checksum "$blob" "blob.tar.gz" "$ck"; then echo "  verify_checksum: expected pass"; rc=1; fi
printf 'tampered' > "$blob"
if verify_checksum "$blob" "blob.tar.gz" "$ck" 2>/dev/null; then echo "  verify_checksum: expected FAIL on mismatch"; rc=1; fi
rm -f "$ck" "$blob"

exit "$rc"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash test/test_install_tools.sh`
Expected: FAIL (`install-tools.sh` does not exist; `source` errors).

- [ ] **Step 3: Write `scripts/install-tools.sh`**

```bash
#!/usr/bin/env bash
# Hermetic installer for the pinned ogham-cli binary (design §13, §14.2 Q4).
# Downloads the pinned release, SHA256-verifies it against checksums.txt (fail loud),
# places it at .tools/ogham, and on macOS ad-hoc signs + de-quarantines it.
set -uo pipefail

REPO="ogham-mcp/ogham-cli"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TOOLS_DIR="${ROOT}/.tools"
VERSION_FILE="${TOOLS_DIR}/.version"

UPGRADE=0
REQ_VERSION="${OGHAM_VERSION:-}"

usage() { echo "usage: install-tools.sh [--upgrade] [--version vX.Y.Z]"; }

detect_asset() {
  local os arch
  case "$(uname -s)" in
    Darwin) os=darwin ;; Linux) os=linux ;;
    *) echo "unsupported OS: $(uname -s)" >&2; return 1 ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;;
    *) echo "unsupported arch: $(uname -m)" >&2; return 1 ;;
  esac
  printf 'ogham-cli-%s-%s.tar.gz\n' "$os" "$arch"
}

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else sha256sum "$1" | awk '{print $1}'; fi
}

# verify_checksum <file> <asset-name> <checksums.txt>: 0 if the file's sha256
# matches the entry for <asset-name>; non-zero (and a stderr message) otherwise.
verify_checksum() {
  local file="$1" name="$2" checks="$3" expected actual
  expected="$(grep "  ${name}\$" "$checks" 2>/dev/null | awk '{print $1}' | head -n1)"
  [ -n "$expected" ] || { echo "checksum for ${name} not found" >&2; return 1; }
  actual="$(sha256_of "$file")"
  if [ "$expected" != "$actual" ]; then
    echo "CHECKSUM MISMATCH for ${name}: expected ${expected}, got ${actual}" >&2
    return 1
  fi
  return 0
}

resolve_version() {
  if [ -n "${REQ_VERSION}" ]; then
    case "${REQ_VERSION}" in v*) printf '%s\n' "${REQ_VERSION}" ;; *) printf 'v%s\n' "${REQ_VERSION}" ;; esac
    return 0
  fi
  if [ "${UPGRADE}" -eq 0 ] && [ -f "${VERSION_FILE}" ]; then
    local v; v="$(tr -d '[:space:]' < "${VERSION_FILE}")"
    case "$v" in v*) printf '%s\n' "$v" ;; *) printf 'v%s\n' "$v" ;; esac
    return 0
  fi
  curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
    | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/'
}

main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --upgrade) UPGRADE=1 ;;
      --version) REQ_VERSION="${2:-}"; shift ;;
      -h|--help) usage; return 0 ;;
      *) echo "unknown arg: $1" >&2; usage; return 2 ;;
    esac
    shift
  done

  local version asset url tmp
  version="$(resolve_version)"
  [ -n "${version}" ] || { echo "could not resolve version" >&2; return 1; }
  asset="$(detect_asset)" || return 1
  url="https://github.com/${REPO}/releases/download/${version}/${asset}"
  tmp="$(mktemp -d)"; trap 'rm -rf "${tmp}"' RETURN

  echo "==> Downloading ${asset} @ ${version}"
  curl -fsSL "${url}" -o "${tmp}/${asset}" || { echo "download failed: ${url}" >&2; return 1; }
  curl -fsSL "https://github.com/${REPO}/releases/download/${version}/checksums.txt" -o "${tmp}/checksums.txt" \
    || { echo "checksums.txt download failed" >&2; return 1; }

  verify_checksum "${tmp}/${asset}" "${asset}" "${tmp}/checksums.txt" || return 1
  echo "==> Checksum OK"

  tar -xzf "${tmp}/${asset}" -C "${tmp}" || { echo "extract failed" >&2; return 1; }
  [ -f "${tmp}/ogham" ] || { echo "archive did not contain 'ogham'" >&2; return 1; }

  mkdir -p "${TOOLS_DIR}"
  mv -f "${tmp}/ogham" "${TOOLS_DIR}/ogham"
  chmod +x "${TOOLS_DIR}/ogham"
  [ -f "${tmp}/LICENSE" ]   && mv -f "${tmp}/LICENSE"   "${TOOLS_DIR}/LICENSE"   || true
  [ -f "${tmp}/README.md" ] && mv -f "${tmp}/README.md" "${TOOLS_DIR}/README.md" || true

  if [ "$(uname -s)" = "Darwin" ]; then
    codesign --force --sign - "${TOOLS_DIR}/ogham" >/dev/null 2>&1 || true
    xattr -dr com.apple.quarantine "${TOOLS_DIR}/ogham" 2>/dev/null || true
  fi

  printf '%s\n' "${version#v}" > "${VERSION_FILE}"
  echo "==> Installed ogham ${version#v} to ${TOOLS_DIR}/ogham"
  if "${TOOLS_DIR}/ogham" version >/dev/null 2>&1; then echo "==> Binary runs OK"; fi
  if [ "${UPGRADE}" -eq 1 ]; then
    echo "==> Upgrade complete. Run the §8.2 replay benchmark before committing .tools/.version."
  fi
}

# Executed directly -> run main. Sourced (tests) -> only define functions.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
```

- [ ] **Step 4: Make executable and run the unit test to verify it passes**

Run: `chmod +x scripts/install-tools.sh && bash test/test_install_tools.sh && echo OK`
Expected: prints `OK`.

- [ ] **Step 5: Integration check — reinstall the pinned version end-to-end**

Run: `bash scripts/install-tools.sh --version v0.7.3 && ./.tools/ogham version`
Expected: `==> Checksum OK`, `==> Installed ogham 0.7.3`, `==> Binary runs OK`, then the version JSON `{"version": "0.7.3", ...}`. (This re-downloads and verifies against the real release; the binary ends up signed + de-quarantined.)

- [ ] **Step 6: Commit**

```bash
git add scripts/install-tools.sh test/test_install_tools.sh
git commit -m "feat: hermetic install-tools.sh with SHA256 verify + macOS sign (§14.2 Q4)"
```

---

## Task 4: Plugin manifest `.claude-plugin/plugin.json`

**Files:**
- Create: `.claude-plugin/plugin.json`

- [ ] **Step 1: Write the manifest**

```json
{
  "$schema": "https://json.schemastore.org/claude-code-plugin-manifest.json",
  "name": "superpowers-memory",
  "description": "Orchestrator-mediated Ogham memory bridge for the superpowers subagent pipeline: per-dispatch lesson recall + staged distilled flush, with subagent isolation preserved by construction.",
  "author": { "name": "Kevin Burns" },
  "keywords": ["ogham", "memory", "superpowers", "subagents", "recall"]
}
```

(No `version` field — Claude Code uses the git SHA during the `--plugin-dir` validation phase per §14.2 Q6. `repository`/`homepage`/`license` are added at publish time, not now.)

- [ ] **Step 2: Validate the manifest**

Run: `claude plugin validate . 2>&1`
Expected: validation passes with no errors (skills/ and hooks/ are added in later tasks; a warning about empty component dirs is acceptable at this step).

- [ ] **Step 3: Commit**

```bash
git add .claude-plugin/plugin.json
git commit -m "feat: superpowers-memory plugin manifest"
```

---

## Task 5: SessionStart hook (`hooks/session-start.sh` + `hooks/hooks.json`)

**Files:**
- Create: `hooks/session-start.sh`, `hooks/hooks.json`
- Test: `test/test_session_start.sh`

- [ ] **Step 1: Write the failing test (hermetic — fake ogham via OGHAM_BIN)**

Create `test/test_session_start.sh`:
```bash
#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${DIR}/.." && pwd)"
HOOK="${ROOT}/hooks/session-start.sh"
rc=0
work="$(mktemp -d)"

# Fake ogham: records 'profile switch' args, emits version JSON matching $FAKE_VERSION.
fake="${work}/ogham"
cat > "$fake" <<'FAKE'
#!/usr/bin/env bash
if [ "$1" = "profile" ] && [ "$2" = "switch" ]; then echo "$3" >> "${OGHAM_CALLS}"; exit 0; fi
if [ "$1" = "version" ]; then printf '{"version": "%s"}\n' "${FAKE_VERSION:-0.7.3}"; exit 0; fi
exit 0
FAKE
chmod +x "$fake"

run_hook() { # args: cwd version_in_file -> prints stdout; sets PROFILE_FILE
  OGHAM_CALLS="${work}/calls"; : > "$OGHAM_CALLS"
  printf '0.7.3\n' > "${ROOT}/.tools/.version"   # baseline pinned version
  printf '{"cwd":"%s"}' "$1" | \
    OGHAM_BIN="$fake" FAKE_VERSION="$2" OGHAM_CALLS="$OGHAM_CALLS" bash "$HOOK"
}

# 1. Always exits 0
printf '{"cwd":"%s"}' "$work" | OGHAM_BIN="$fake" FAKE_VERSION=0.7.3 OGHAM_CALLS="${work}/c" bash "$HOOK" >/dev/null 2>&1
[ $? -eq 0 ] || { echo "  exit: expected 0"; rc=1; }

# 2. Bootstraps a superpowers-<slug> profile
out_calls="${work}/calls2"; : > "$out_calls"
printf '{"cwd":"%s"}' "$work" | OGHAM_BIN="$fake" FAKE_VERSION=0.7.3 OGHAM_CALLS="$out_calls" bash "$HOOK" >/dev/null 2>&1
grep -q '^superpowers-' "$out_calls" || { echo "  profile: expected superpowers-* switch, got '$(cat "$out_calls")'"; rc=1; }

# 3. Drift warning when installed != pinned
printf '0.7.3\n' > "${ROOT}/.tools/.version"
drift="$(printf '{"cwd":"%s"}' "$work" | OGHAM_BIN="$fake" FAKE_VERSION=0.9.9 OGHAM_CALLS="${work}/c3" bash "$HOOK" 2>&1)"
echo "$drift" | grep -qi 'drift' || { echo "  drift: expected drift warning"; rc=1; }

# 4. Orphan-buffer report when buffer is non-empty
echo '{"type":"decision","text":"x"}' > "${work}/.superpowers-lessons.jsonl"
orphan="$(printf '{"cwd":"%s"}' "$work" | OGHAM_BIN="$fake" FAKE_VERSION=0.7.3 OGHAM_CALLS="${work}/c4" bash "$HOOK" 2>&1)"
echo "$orphan" | grep -qi 'orphan' || { echo "  orphan: expected orphaned-buffer report"; rc=1; }

rm -rf "$work"
exit "$rc"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash test/test_session_start.sh`
Expected: FAIL (hook does not exist).

- [ ] **Step 3: Write `hooks/session-start.sh`**

```bash
#!/usr/bin/env bash
# SessionStart hook (design §4.2, §13.3, §14.5). Best-effort: ALWAYS exits 0.
# 1) eager per-repo profile bootstrap  2) ogham-version drift check  3) orphan-buffer report.
set -uo pipefail   # deliberately NOT -e: every failure must still reach exit 0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}"

STDIN_JSON="$(cat 2>/dev/null || true)"
CWD="$(printf '%s' "${STDIN_JSON}" | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
[ -n "${CWD}" ] || CWD="$PWD"

OGHAM="$(bash "${ROOT}/scripts/ogham-bin.sh" 2>/dev/null || true)"
if [ -z "${OGHAM}" ]; then
  echo "superpowers-memory: ogham binary not found; recall disabled this session (run scripts/install-tools.sh)."
  exit 0
fi

# Per-repo profile slug: git remote basename, else cwd basename; sanitized.
repo_slug() {
  local url base
  url="$(git -C "${CWD}" config --get remote.origin.url 2>/dev/null || true)"
  if [ -n "${url}" ]; then base="${url##*/}"; base="${base%.git}"; else base="$(basename "${CWD}")"; fi
  base="$(printf '%s' "${base}" | tr '[:upper:] ' '[:lower:]-' | tr -cd '[:alnum:]-')"
  printf 'superpowers-%s' "${base}"
}
PROFILE="$(repo_slug)"

# 1. eager profile bootstrap (auto-create on switch)
"${OGHAM}" profile switch "${PROFILE}" >/dev/null 2>&1 || true

# 2. binary drift check (ogham version subcommand -> JSON .version)
INSTALLED="$("${OGHAM}" version 2>/dev/null | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
PINNED="$(tr -d '[:space:]' < "${ROOT}/.tools/.version" 2>/dev/null || true)"
if [ -n "${PINNED}" ] && [ -n "${INSTALLED}" ] && [ "${INSTALLED}" != "${PINNED}" ]; then
  echo "superpowers-memory: ogham version drift (installed ${INSTALLED}, pinned ${PINNED}). Run scripts/install-tools.sh --upgrade."
fi

# 3. orphan-buffer report (distilled flush is gated on the §8.2 benchmark — v0.1 only reports)
BUFFER="${CWD}/.superpowers-lessons.jsonl"
if [ -s "${BUFFER}" ]; then
  n="$(wc -l < "${BUFFER}" | tr -d ' ')"
  echo "superpowers-memory: orphaned staging buffer (${n} candidates) — run /superpowers-memory:flush to distill."
fi

exit 0
```

- [ ] **Step 4: Write `hooks/hooks.json`**

```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "",
        "hooks": [
          { "type": "command", "command": "\"${CLAUDE_PLUGIN_ROOT}\"/hooks/session-start.sh" }
        ]
      }
    ]
  }
}
```

- [ ] **Step 5: Make executable and run the hook test to verify it passes**

Run: `chmod +x hooks/session-start.sh && bash test/test_session_start.sh && echo OK`
Expected: prints `OK`.

- [ ] **Step 6: Restore the real pinned version (the test wrote to `.tools/.version`)**

Run: `printf '0.7.3\n' > .tools/.version && cat .tools/.version`
Expected: `0.7.3`.

- [ ] **Step 7: Re-validate the plugin and commit**

Run: `claude plugin validate . 2>&1` (expect: passes)
```bash
git add hooks/hooks.json hooks/session-start.sh test/test_session_start.sh
git commit -m "feat: best-effort SessionStart hook (profile bootstrap + drift check + orphan report)"
```

---

## Task 6: Core skill `skills/superpowers-memory/SKILL.md` + buffer schema

**Files:**
- Create: `skills/superpowers-memory/SKILL.md`, `skills/superpowers-memory/buffer-schema.md`

- [ ] **Step 1: Write the staging-buffer schema**

Create `skills/superpowers-memory/buffer-schema.md`:
```markdown
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
```

- [ ] **Step 2: Write the skill**

Create `skills/superpowers-memory/SKILL.md`:
```markdown
---
name: superpowers-memory
description: Orchestrator-only bridge to Ogham durable lessons for the superpowers subagent pipeline. Use ONLY from the orchestrator/controller (never a subagent) to recall per-task lessons before dispatch and to flush captured lessons. Exposes two verbs - recall and flush.
disable-model-invocation: true
---

# superpowers-memory

A bridge so the **orchestrator** (and only the orchestrator) can reuse durable lessons from Ogham
without breaking subagent context isolation. Subagents must never invoke this skill or the `ogham`
binary — that is the load-bearing invariant (design §4.1). All reads/writes flow through the
orchestrator or a scribe it dispatches.

## Resolve the binary first (always)

Every Bash step below resolves the pinned binary via the shared resolver (design §13.2):

```bash
OGHAM="$("${CLAUDE_PLUGIN_ROOT:-$PWD}/scripts/ogham-bin.sh")" || {
  echo "superpowers-memory: no ogham binary; recall unavailable (graceful degradation)."; exit 0; }
```

If resolution fails, **degrade gracefully** — continue with empty recall, never block a dispatch
(design §6).

## Verb: `recall` (WIRED)

Before dispatching a subagent, recall lessons scoped to the current task and fold the result into the
**curated prompt** you are about to send (do NOT edit files on disk; do NOT let the subagent call
this skill). Use the active per-repo profile (bootstrapped by the SessionStart hook).

```bash
# Relevance-ranked top-K lessons for this task. `ogham search` takes a POSITIONAL query
# (not --query) and runs native hybrid (vector + keyword) search against the active profile.
# JSON output by default; sub-100ms native Go path (design §9).
"$OGHAM" search "<short description of the task you are about to dispatch>" --limit 5 2>/dev/null || true

# Optional: a cached wiki-preamble at a chosen resolution — this is the §4.3 `wiki_preamble_level`
# knob (one_line / short / body). Phase 2 tunes the level by budget; not required for v0.1 recall.
# "$OGHAM" recall topic-summary "<topic>" 2>/dev/null || true
```

> Note: `ogham search` needs `DATABASE_URL` + `EMBEDDING_PROVIDER` + the provider key configured. If
> they aren't, the command fails and the `|| true` degrades to empty recall (design §6) — never block.

Fold the returned lessons into the dispatch prompt as **hints to verify, not gospel**, each stamped
with its `(when, commit, source-task)` provenance. Budget: keep total recall injection per dispatch
to roughly 1500 tokens; prefer short preambles, and when many lessons return, summarize rather than
paste. If recall returns nothing relevant, inject a single line: *"No proven lesson exists for this
task shape yet"* and consider widening the subagent's exploration budget.

## Verb: `flush` (STUBBED — gated on the §8.2 benchmark)

Capture and distilled flush are **not implemented in v0.1**. The interface is fixed so Phase 2 only
fills in the body:

- **Capture** (future): after a task's two-stage review passes AND it surfaced signal (a reviewer
  caught something / implementer hit BLOCKED then resolved / a decision was made / a finding
  repeated), append one typed candidate to `./.superpowers-lessons.jsonl` per `buffer-schema.md`.
  Clean tasks write nothing.
- **Flush** (future, every N=3 candidates + at branch-finish): a scribe reads the buffer, dedupes/
  merges against existing repo memories, distills survivors (<=500 tokens each), and writes them with
  `source="superpowers-scribe"`, tags, and TTL, then clears the buffer.

Until the benchmark proves positive, `flush` only reports the buffer state:

```bash
BUFFER="${PWD}/.superpowers-lessons.jsonl"
if [ -s "$BUFFER" ]; then
  echo "superpowers-memory: $(wc -l < "$BUFFER" | tr -d ' ') candidate(s) staged. Distilled flush is gated on the §8.2 replay benchmark (not yet enabled)."
else
  echo "superpowers-memory: staging buffer empty."
fi
```

See `buffer-schema.md` for the candidate format and the §5 taxonomy that bounds what may ever be stored.
```

- [ ] **Step 3: Validate the plugin**

Run: `claude plugin validate . 2>&1`
Expected: passes; the skill `superpowers-memory` is discovered.

- [ ] **Step 4: Commit**

```bash
git add skills/superpowers-memory/SKILL.md skills/superpowers-memory/buffer-schema.md
git commit -m "feat: superpowers-memory skill (recall wired, flush stubbed) + buffer schema"
```

---

## Task 7: Manual flush entry point `skills/flush/SKILL.md`

**Files:**
- Create: `skills/flush/SKILL.md`

- [ ] **Step 1: Write the skill**

Create `skills/flush/SKILL.md`:
```markdown
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
```

- [ ] **Step 2: Validate and confirm both skills are discovered**

Run: `claude plugin validate . 2>&1`
Expected: passes; both `superpowers-memory` and `flush` skills are listed.

- [ ] **Step 3: Commit**

```bash
git add skills/flush/SKILL.md
git commit -m "feat: /superpowers-memory:flush manual entry point"
```

---

## Task 8: End-to-end smoke + README

**Files:**
- Create: `README.md`

- [ ] **Step 1: Run the full test suite**

Run: `bash test/run.sh && echo ALL-GREEN`
Expected: every `test_*.sh` prints `PASS`, final line `ALL-GREEN`.

- [ ] **Step 2: Validate the full plugin**

Run: `claude plugin validate . 2>&1`
Expected: passes with the manifest, two skills, and the SessionStart hook all recognized.

- [ ] **Step 3: Smoke-test the hook as Claude Code will run it**

Run:
```bash
printf '{"cwd":"%s"}' "$PWD" | CLAUDE_PLUGIN_ROOT="$PWD" bash hooks/session-start.sh
```
Expected: exits 0; prints a drift line only if versions differ; prints an orphan line only if `.superpowers-lessons.jsonl` is non-empty; otherwise silent. The profile `superpowers-ogham-superpower-bridge` is created/active (verify: `./.tools/ogham profile current`).

- [ ] **Step 4: Write `README.md`**

```markdown
# superpowers-memory

A Claude Code plugin: an orchestrator-mediated bridge from the [superpowers](https://github.com/) subagent
pipeline to durable lessons in [Ogham](https://github.com/ogham-mcp/ogham-cli), without breaking subagent
context isolation. Design: `2026-05-29-superpowers-ogham-memory-bridge-design.md`.

## Status
v0.1 scaffold. `recall` is wired to the native `ogham` CLI; capture + distilled flush are **gated on a
positive §8.2 replay benchmark**. Private build — load with `claude --plugin-dir .`.

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
```

- [ ] **Step 5: Commit**

```bash
git add README.md
git commit -m "docs: README for superpowers-memory v0.1 scaffold"
```

---

## Phase 2 (GATED — do NOT implement in this plan)

These require a **positive §8.2 replay benchmark** (Council Q5). They are intentionally absent above
so a negative benchmark means there is no scribe code to delete — the plugin simply degrades to empty
recall. When the benchmark passes (per the user-confirmed threshold), write a follow-up plan covering:

1. **Capture signal-gate** — append typed candidates to the buffer only on real signal (§4.3).
2. **Scribe distillation** — the prompt that turns raw candidates into <=500-token lessons.
3. **Flush dedupe/merge** — against existing repo memories; idempotent writes; `source="superpowers-scribe"`; TTL + tags.
4. **Recall-injection real logic** — `wiki_preamble_level` budget, `gap_note` handling (§4.3), provenance framing.
5. **Measurement harness** — recall-on vs recall-off, hit-rate / redundant-exploration / repeat-mistake (§8.3).
6. **Disable smart-inscribe** on the profile (only the scribe writes) (§4.2).
7. **Distribution** — real semver in `plugin.json`, `.claude-plugin/marketplace.json`, switch resolution to `${CLAUDE_PLUGIN_DATA}`-first (§14.2 Q3/Q6).

**Open user decisions that gate Phase 2:** benchmark pass threshold; transcript corpus selection;
marketplace identity (author/repo/license). See design §14.6.
```
