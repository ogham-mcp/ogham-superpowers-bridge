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

exit "$rc"
