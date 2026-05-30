#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${DIR}/.." && pwd)"
# Source the installer WITHOUT running main() (guarded by BASH_SOURCE check).
# shellcheck disable=SC1090
source "${ROOT}/scripts/install-tools.sh"
rc=0
trap 'rm -f "${tmp:-}" "${ck:-}" "${blob:-}"' EXIT

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

# classify_ogham: version-string -> go-cli | mcp | unknown
[ "$(classify_ogham 0.7.5)" = "go-cli" ]  || { echo "  classify: 0.7.5 should be go-cli"; rc=1; }
[ "$(classify_ogham 0.13.9)" = "go-cli" ] || { echo "  classify: 0.13.9 should be go-cli"; rc=1; }
[ "$(classify_ogham 0.14.3)" = "mcp" ]    || { echo "  classify: 0.14.3 should be mcp"; rc=1; }
[ "$(classify_ogham 1.0.0)" = "mcp" ]     || { echo "  classify: 1.0.0 should be mcp"; rc=1; }
[ "$(classify_ogham '')" = "unknown" ]    || { echo "  classify: empty should be unknown"; rc=1; }
[ "$(classify_ogham 0abc)" = "unknown" ]  || { echo "  classify: non-numeric major should be unknown"; rc=1; }
[ "$(classify_ogham v0.7.3)" = "unknown" ] || { echo "  classify: v-prefixed should be unknown"; rc=1; }

# --use-system integration: adopt a Go-CLI fake (subprocess; isolated TOOLS_DIR; never touch real .tools)
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="${ROOT_DIR}/scripts/install-tools.sh"
td="$(mktemp -d)"
fakego="${td}/ogham-go"; cat > "$fakego" <<'FK'
#!/usr/bin/env bash
[ "$1" = "version" ] && { printf '{"version":"0.7.9","commit":"abc","go":"go1.26"}\n'; exit 0; }
exit 0
FK
chmod +x "$fakego"
out="$(SUPERPOWERS_TOOLS_DIR="${td}/tools" OGHAM_BIN="$fakego" bash "$INSTALL" --use-system 2>&1)"; ec=$?
[ "$ec" = "0" ] || { echo "  use-system go: expected exit 0, got $ec ($out)"; rc=1; }
[ -L "${td}/tools/ogham" ] || { echo "  use-system go: expected .tools/ogham symlink"; rc=1; }
[ "$(cat "${td}/tools/.version" 2>/dev/null)" = "0.7.9" ] || { echo "  use-system go: expected .version 0.7.9"; rc=1; }

# --use-system rejects an MCP-versioned (>=0.14) fake
fakemcp="${td}/ogham-mcp"; cat > "$fakemcp" <<'FK'
#!/usr/bin/env bash
[ "$1" = "version" ] && { printf '{"version":"0.14.3"}\n'; exit 0; }
exit 0
FK
chmod +x "$fakemcp"
td2="$(mktemp -d)"
if SUPERPOWERS_TOOLS_DIR="${td2}/tools" OGHAM_BIN="$fakemcp" bash "$INSTALL" --use-system >/dev/null 2>&1; then
  echo "  use-system mcp: expected rejection (>=0.14)"; rc=1; fi
[ -e "${td2}/tools/ogham" ] && { echo "  use-system mcp: must NOT create a symlink on reject"; rc=1; }

# --use-system rejects a binary with NO version command (simulates Python: errors)
fakenov="${td}/ogham-nov"; printf '#!/usr/bin/env bash\nexit 1\n' > "$fakenov"; chmod +x "$fakenov"
td3="$(mktemp -d)"
if SUPERPOWERS_TOOLS_DIR="${td3}/tools" OGHAM_BIN="$fakenov" bash "$INSTALL" --use-system >/dev/null 2>&1; then
  echo "  use-system nover: expected rejection (no version JSON)"; rc=1; fi
[ -e "${td3}/tools/ogham" ] && { echo "  use-system nover: must NOT create a symlink on reject"; rc=1; }

rm -rf "$td" "$td2" "$td3"

exit "$rc"
