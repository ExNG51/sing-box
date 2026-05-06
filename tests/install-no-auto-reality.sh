#!/usr/bin/env bash
set -euo pipefail

fail() {
    printf '[FAIL] %s\n' "$1" >&2
    exit 1
}

MATCH_OUTPUT="$(mktemp)"
trap 'rm -f "$MATCH_OUTPUT"' EXIT

find_matches() {
    local pattern="$1"
    shift

    if command -v rg >/dev/null 2>&1; then
        rg -n "$pattern" "$@" >"$MATCH_OUTPUT" 2>/dev/null
    else
        grep -REn "$pattern" "$@" >"$MATCH_OUTPUT" 2>/dev/null
    fi
}

assert_no_match() {
    local pattern="$1"
    local description="$2"
    if find_matches "$pattern" install.sh src; then
        cat "$MATCH_OUTPUT" >&2
        fail "$description"
    fi
}

assert_match() {
    local pattern="$1"
    local file="$2"
    local description="$3"
    find_matches "$pattern" "$file" || fail "$description"
}

shopt -s nullglob
for file in install.sh sing-box.sh src/*.sh; do
    bash -n "$file"
done

assert_no_match '^[[:space:]]*(sb|sing-box)?[[:space:]]*add[[:space:]]+reality([[:space:]]|$)' \
    'install flow must not automatically create Reality configs'

assert_match 'r \| reality\)|VLESS-REALITY' src/core.sh \
    'manual Reality support must remain available'

assert_match 'No proxy protocol has been created automatically|未自动创建任何代理协议' install.sh \
    'install completion must explain that no protocol was created automatically'

assert_match 'After installation, no proxy protocol is created automatically|安装完成后不会自动创建任何代理协议配置' README.md \
    'README must document that installation does not create a protocol automatically'

assert_match '\[ -t 0 \].*\[ -t 1 \]' install.sh \
    'post-install menu entry must be gated on interactive stdin/stdout'

assert_match 'run: bash tests/install-no-auto-reality.sh' .github/workflows/release.yml \
    'release workflow must run no-auto-reality checks before packaging'

awk '
    /run: bash tests\/install-no-auto-reality\.sh/ { check_line = NR }
    /- name: tar/ { tar_line = NR }
    END { exit !(check_line && tar_line && check_line < tar_line) }
' .github/workflows/release.yml || fail 'release workflow no-auto-reality checks must run before the tar step'

printf '[PASS] install no-auto-reality checks\n'
