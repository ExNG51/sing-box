#!/usr/bin/env bash
set -euo pipefail

fail() {
    printf '[FAIL] %s\n' "$1" >&2
    exit 1
}

assert_contains() {
    local file=$1
    local text=$2
    local description=$3

    grep -Fq -- "$text" "$file" || fail "$description"
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$REPO_ROOT/.github/workflows/release.yml"
TMP_OUT="$(mktemp)"
trap 'rm -f "$TMP_OUT"' EXIT

if awk '
    /^[[:space:]]*#/ { next }
    /(^|[;&|[:space:]])rg[[:space:]]+/ {
        printf "%s:%d:%s\n", FILENAME, FNR, $0
        found = 1
    }
    END { exit found ? 0 : 1 }
' "$REPO_ROOT"/tests/audit/*.sh >"$TMP_OUT" 2>&1; then
    cat "$TMP_OUT" >&2
    fail 'audit tests must not require ripgrep in CI'
fi

if grep -nE 'apt(-get)?[[:space:]].*install.*ripgrep|cargo[[:space:]]+install[[:space:]]+ripgrep' "$WORKFLOW" >"$TMP_OUT" 2>&1; then
    cat "$TMP_OUT" >&2
    fail 'release workflow must not install ripgrep for audit tests'
fi

assert_contains "$WORKFLOW" 'for file in tests/audit/*.sh' \
    'release workflow must run tests/audit/*.sh when present'

for audit_script in "$REPO_ROOT"/tests/audit/*.sh; do
    [[ -f $audit_script ]] || continue
    bash -n "$audit_script"
done

printf '[PASS] audit dependency baseline checks\n'
