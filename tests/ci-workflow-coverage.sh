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

[[ -f $WORKFLOW ]] || fail 'release workflow must exist'

assert_contains "$WORKFLOW" 'bash -n src/tuic.sh' \
    'release workflow must syntax-check src/tuic.sh'
assert_contains "$WORKFLOW" 'bash -n src/tuic_port_hopping.sh' \
    'release workflow must syntax-check src/tuic_port_hopping.sh'
assert_contains "$WORKFLOW" 'for file in tests/*.sh' \
    'release workflow must run the full tests/*.sh matrix'
assert_contains "$WORKFLOW" 'for file in tests/audit/*.sh' \
    'release workflow must run tests/audit/*.sh when present'

printf '[PASS] CI workflow coverage checks\n'
