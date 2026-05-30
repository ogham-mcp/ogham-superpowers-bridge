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
