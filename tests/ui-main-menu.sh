#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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

assert_no_match() {
    local pattern=$1
    local file=$2
    local description=$3

    if command -v rg >/dev/null 2>&1; then
        if rg -n "$pattern" "$file" >/dev/null; then
            fail "$description"
        fi
    else
        if grep -En "$pattern" "$file" >/dev/null; then
            fail "$description"
        fi
    fi
}

assert_contains() {
    local text=$1
    local file=$2
    local description=$3

    grep -Fq -- "$text" "$file" || fail "$description"
}

for file in sing-box.sh src/*.sh tests/*.sh; do
    [[ -e $REPO_ROOT/$file ]] || continue
    bash -n "$REPO_ROOT/$file"
done

assert_match '^ui_init_colors\(\)' "$REPO_ROOT/src/init.sh" \
    'src/init.sh must define ui_init_colors'
assert_match '^ui_print\(\)' "$REPO_ROOT/src/init.sh" \
    'src/init.sh must define ui_print'
assert_match '^ui_blank\(\)' "$REPO_ROOT/src/init.sh" \
    'src/init.sh must define ui_blank'
assert_match '^ui_(green|yellow|red|cyan|blue|magenta|red_bg)_text\(\)' "$REPO_ROOT/src/init.sh" \
    'src/init.sh must define inline ui color helpers'
assert_match 'NO_COLOR' "$REPO_ROOT/src/init.sh" \
    'ui_init_colors must respect NO_COLOR'
assert_match 'TERM:-.*dumb' "$REPO_ROOT/src/init.sh" \
    'ui_init_colors must respect TERM=dumb'
assert_match 'FORCE_COLOR' "$REPO_ROOT/src/init.sh" \
    'ui_init_colors must support FORCE_COLOR'
assert_match '!-t 1|! -t 1' "$REPO_ROOT/src/init.sh" \
    'ui_init_colors must disable color when stdout is not a TTY'

assert_match '^msg\(\)[[:space:]]*\{[[:space:]]*ui_print "\$@"' "$REPO_ROOT/src/core.sh" \
    'msg must remain a raw output wrapper over ui_print'
assert_no_match '^msg\(\)[[:space:]]*\{[[:space:]]*ui_info' "$REPO_ROOT/src/core.sh" \
    'msg must not be remapped to ui_info'
assert_match '^_green\(\)[[:space:]]*\{[[:space:]]*ui_green_text "\$@"' "$REPO_ROOT/src/init.sh" \
    '_green must remain an inline color helper'
assert_no_match '^_green\(\)[[:space:]]*\{[[:space:]]*ui_ok' "$REPO_ROOT/src/init.sh" \
    '_green must not be remapped to ui_ok'

assert_match 'ui_title "sing-box 管理脚本" "\$is_sh_ver"' "$REPO_ROOT/src/core.sh" \
    'main menu must use ui_title'
assert_match '^build_main_status_line\(\)' "$REPO_ROOT/src/core.sh" \
    'src/core.sh must define build_main_status_line'
assert_match 'ui_dim "\$\(build_main_status_line\)"' "$REPO_ROOT/src/core.sh" \
    'main menu must show the condensed status summary'
assert_match 'ask mainmenu' "$REPO_ROOT/src/core.sh" \
    'is_main_menu must still call ask mainmenu'
assert_match 'case \$REPLY in' "$REPO_ROOT/src/core.sh" \
    'main menu must still dispatch on REPLY'
assert_match 'ui_menu_item 0 "退出"' "$REPO_ROOT/src/core.sh" \
    'main menu exit option must stay on 0 and use point-style rendering'

assert_match 'url \| qr\)' "$REPO_ROOT/src/core.sh" \
    'url/qr command branch must remain present'
assert_contains 'msg "\e[4;${is_color}m${is_url}\e[0m"' "$REPO_ROOT/src/core.sh" \
    'URL output body must remain unchanged'
assert_contains 'is_anytls_tls="tls:{enabled:true,certificate_provider:\"$is_anytls_acme_tag\"}"' "$REPO_ROOT/src/core.sh" \
    'AnyTLS 1.14+ ACME schema logic must remain present'
assert_match 'commit_server_config_with_validation' "$REPO_ROOT/src/core.sh" \
    'AnyTLS ACME transaction path must remain present'

assert_match '^is_sh_ver=v1\.22$' "$REPO_ROOT/sing-box.sh" \
    'sing-box.sh must bump the manager version to v1.22'

printf '[PASS] UI main menu checks\n'
