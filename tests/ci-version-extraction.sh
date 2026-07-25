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

# --- Simulate the fixed CI extraction logic against sing-box.sh alone ---
extracted=$(printf 'is_sh_ver=%s\n' "$(grep -m1 -oE 'v[0-9]+(\.[0-9]+)+' "$REPO_ROOT/sing-box.sh")")
[[ $extracted == "is_sh_ver=v1.33" ]] || fail "CI version extraction must produce is_sh_ver=v1.33 (got: $extracted)"

# --- Verify it does NOT double-prefix (rev1 bug) ---
[[ $extracted != "is_sh_ver=is_sh_ver="* ]] || fail "CI version extraction must not double-prefix is_sh_ver="

# --- Robustness: even if a second .sh has is_sh_ver=, sing-box.sh grep reads only sing-box.sh ---
# (cannot easily simulate cat *.sh here, but the fix reads sing-box.sh explicitly)
grep -m1 -oE 'v[0-9]+(\.[0-9]+)+' "$REPO_ROOT/sing-box.sh" >/dev/null 2>&1 || \
    fail "sing-box.sh must contain a v<x>.<y> version string"

# --- Contract: release.yml must use the explicit sing-box.sh grep, not cat *.sh ---
grep -q 'grep -m1.*sing-box.sh' "$REPO_ROOT/.github/workflows/release.yml" || \
    fail "release.yml must grep sing-box.sh explicitly for version"
grep -q 'cat \*.sh' "$REPO_ROOT/.github/workflows/release.yml" && \
    fail "release.yml must not use 'cat *.sh' for version extraction" || true

printf '[PASS] ci version extraction checks\n'
