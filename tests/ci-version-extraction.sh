#!/usr/bin/env bash
set -uo pipefail

# P2-04: CI version extraction must produce exactly one correct is_sh_ver= line
# from sing-box.sh, even if other .sh files also contain is_sh_ver=.

fail() {
    printf '[FAIL] %s\n' "$1" >&2
    exit 1
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/sb-civer.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

# shellcheck source=tests/lib/version.sh
. "$REPO_ROOT/tests/lib/version.sh"

# --- Simulate the fixed CI extraction logic against sing-box.sh alone ---
extracted=$(printf 'is_sh_ver=%s\n' "$(grep -m1 -oE 'v[0-9]+(\.[0-9]+)+' "$REPO_ROOT/sing-box.sh")")
# Read expected version from the exact launcher declaration, independently of the CI grep.
expected_ver=$(manager_version_from_launcher "$REPO_ROOT/sing-box.sh") || \
    fail "sing-box.sh must contain exactly one valid is_sh_ver declaration"
expected="is_sh_ver=$expected_ver"
[[ $extracted == "$expected" ]] || fail "CI version extraction must produce $expected (got: $extracted)"

# --- Verify it does NOT double-prefix (rev1 bug) ---
[[ $extracted != "is_sh_ver=is_sh_ver="* ]] || fail "CI version extraction must not double-prefix is_sh_ver="

# --- Independent-oracle fixtures ---
stray_version_launcher="$TEST_ROOT/stray-version.sh"
printf '%s\n' '# release-note v9.99' 'is_sh_ver=v1.34' > "$stray_version_launcher"
declared_ver=$(manager_version_from_launcher "$stray_version_launcher") || \
    fail "exact declaration parser must accept a valid launcher with a stray version comment"
stray_extracted=$(printf 'is_sh_ver=%s\n' "$(grep -m1 -oE 'v[0-9]+(\.[0-9]+)+' "$stray_version_launcher")")
[[ $stray_extracted != "is_sh_ver=$declared_ver" ]] || \
    fail "CI extraction test must detect a stray version string before is_sh_ver"

duplicate_launcher="$TEST_ROOT/duplicate-version.sh"
printf '%s\n' 'is_sh_ver=v1.34' 'is_sh_ver=v1.35' > "$duplicate_launcher"
manager_version_from_launcher "$duplicate_launcher" >/dev/null 2>&1 && \
    fail "version parser must reject duplicate is_sh_ver declarations" || true

malformed_duplicate_launcher="$TEST_ROOT/malformed-duplicate-version.sh"
printf '%s\n' 'is_sh_ver=v1.34' 'is_sh_ver=not-a-version' > "$malformed_duplicate_launcher"
manager_version_from_launcher "$malformed_duplicate_launcher" >/dev/null 2>&1 && \
    fail "version parser must reject an additional malformed is_sh_ver declaration" || true

missing_launcher="$TEST_ROOT/missing-version.sh"
printf '%s\n' '# no manager version' > "$missing_launcher"
manager_version_from_launcher "$missing_launcher" >/dev/null 2>&1 && \
    fail "version parser must reject a missing is_sh_ver declaration" || true

# --- Contract: release.yml must use the explicit sing-box.sh grep, not cat *.sh ---
grep -q 'grep -m1.*sing-box.sh' "$REPO_ROOT/.github/workflows/release.yml" || \
    fail "release.yml must grep sing-box.sh explicitly for version"
grep -q 'cat \*.sh' "$REPO_ROOT/.github/workflows/release.yml" && \
    fail "release.yml must not use 'cat *.sh' for version extraction" || true

printf '[PASS] ci version extraction checks\n'
