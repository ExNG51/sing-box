#!/usr/bin/env bash
set -euo pipefail

fail() {
    printf '[FAIL] %s\n' "$1" >&2
    exit 1
}

assert_match() {
    local pattern=$1
    local file=$2
    local description=$3

    if command -v rg >/dev/null 2>&1; then
        rg -n "$pattern" "$file" >/dev/null || fail "$description"
    else
        grep -En "$pattern" "$file" >/dev/null || fail "$description"
    fi
}

assert_order() {
    local first_pattern=$1
    local second_pattern=$2
    local file=$3
    local description=$4
    local first second

    first=$(awk -v pat="$first_pattern" '$0 ~ pat { print NR; exit }' "$file")
    second=$(awk -v pat="$second_pattern" '$0 ~ pat { print NR; exit }' "$file")
    [[ $first && $second && $first -lt $second ]] || fail "$description"
}

shopt -s nullglob
for file in install.sh sing-box.sh src/*.sh; do
    bash -n "$file"
done

assert_match 'set_anytls_cert' src/core.sh \
    'menu AnyTLS flow must ask whether to apply for a certificate'
assert_match 'is_default_arg=.*yes' src/core.sh \
    'AnyTLS certificate prompt must default to yes'
assert_match 'is_use_port=443' src/core.sh \
    'AnyTLS certificate menu path must use port 443'
assert_match 'ask string is_anytls_domain' src/core.sh \
    'AnyTLS certificate menu path must prompt for a domain'
assert_match 'is_main_anytls_acme' src/core.sh \
    'AnyTLS certificate menu path must enter the same validation path as explicit args'
assert_match "is_ask_set == 'is_anytls_domain'" src/core.sh \
    'AnyTLS domain prompt must validate domain input'
assert_match 'run: bash tests/anytls-menu-certificate\.sh' .github/workflows/release.yml \
    'release workflow must run AnyTLS menu certificate checks before packaging'
assert_order 'run: bash tests/anytls-menu-certificate\.sh' '- name: tar' .github/workflows/release.yml \
    'release workflow AnyTLS menu checks must run before the tar step'

printf '[PASS] AnyTLS menu certificate checks\n'
