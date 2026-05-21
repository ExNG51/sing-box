#!/usr/bin/env bash
set -o pipefail

fail() {
    printf '[FAIL] %s\n' "$1" >&2
    exit 1
}

pass() {
    printf '[PASS] %s\n' "$1"
}

assert_match() {
    local pattern=$1
    local file=$2
    local description=$3

    if command -v rg >/dev/null 2>&1; then
        rg -n -- "$pattern" "$file" >/dev/null || fail "$description"
    else
        grep -En "$pattern" "$file" >/dev/null || fail "$description"
    fi
}

assert_not_match() {
    local pattern=$1
    local file=$2
    local description=$3

    if command -v rg >/dev/null 2>&1; then
        rg -n -- "$pattern" "$file" >/dev/null && fail "$description"
    else
        grep -En "$pattern" "$file" >/dev/null && fail "$description"
    fi
}

assert_order() {
    local first=$1
    local second=$2
    local file=$3
    local description=$4
    local first_line second_line

    first_line=$(grep -nF "$first" "$file" | head -n 1 | cut -d: -f1)
    second_line=$(grep -nF "$second" "$file" | head -n 1 | cut -d: -f1)
    [[ $first_line && $second_line && $first_line -lt $second_line ]] || fail "$description"
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE_FILE="$REPO_ROOT/src/core.sh"
TUIC_FILE="$REPO_ROOT/src/tuic.sh"
HELP_FILE="$REPO_ROOT/src/help.sh"

bash -n "$CORE_FILE" || fail "src/core.sh syntax must be valid"
bash -n "$TUIC_FILE" || fail "src/tuic.sh syntax must be valid"
bash -n "$HELP_FILE" || fail "src/help.sh syntax must be valid"

assert_match '^route_tuic_add_to_structured\(\)' "$CORE_FILE" \
    "core.sh should expose a single TUIC add routing helper"
assert_match 'route_tuic_add_to_structured "\$@"' "$CORE_FILE" \
    "add() should call the TUIC routing helper"
assert_order 'route_tuic_add_to_structured "$@"' 'case ${is_new_protocol,,} in' "$CORE_FILE" \
    "TUIC routing should happen before the generic add option matrix"
assert_match 'tuic_menu_add_config' "$CORE_FILE" \
    "main-menu TUIC add should enter the structured TUIC add menu"
assert_match 'tuic_add --port "\$legacy_port" --uuid "\$legacy_uuid" --password auto --insecure' "$CORE_FILE" \
    "legacy add tuic should forward to structured TUIC add with auto password"
assert_match 'Legacy TUIC add compatibility entry' "$CORE_FILE" \
    "legacy add tuic should print an explicit compatibility warning"
assert_match 'Production use: .*sing-box tuic add' "$CORE_FILE" \
    "legacy add tuic warning should point to sing-box tuic add"
assert_match 'tuic_generate_password' "$CORE_FILE" \
    "generic TUIC rendering fallback should be able to generate independent passwords"
tuic_branch=$(awk '/tuic\*\)/,/trojan\*\)/' "$CORE_FILE")
[[ $tuic_branch != *'password=$uuid'* ]] || fail "TUIC generic renderer must not default password to uuid"

assert_match 'sing-box tuic add --domain example\.com --tls acme' "$HELP_FILE" \
    "help should recommend structured TUIC ACME add"
assert_match 'sing-box tuic add --domain example\.com --cert-file' "$HELP_FILE" \
    "help should recommend structured TUIC file-cert add"
assert_match 'sing-box tuic add --insecure' "$HELP_FILE" \
    "help should document structured insecure add"
assert_match 'sing-box add tuic.*legacy compatibility entry' "$HELP_FILE" \
    "help should mark generic add tuic as legacy compatibility"

pass "TUIC path unification static checks"
