#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sing-box-main-menu.XXXXXX")"
OUTPUT_FILE="$TMP_DIR/main-menu.out"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
    printf '[FAIL] %s\n' "$1" >&2
    [[ -f $OUTPUT_FILE ]] && {
        printf '%s\n' '--- captured output ---' >&2
        cat "$OUTPUT_FILE" >&2
        printf '%s\n' '-----------------------' >&2
    }
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

assert_line_order() {
    local first_text=$1
    local second_text=$2
    local file=$3
    local description=$4
    local first_line=
    local second_line=

    first_line=$(awk -v text="$first_text" 'index($0, text) { print NR; exit }' "$file")
    second_line=$(awk -v text="$second_text" 'index($0, text) { print NR; exit }' "$file")

    [[ $first_line && $second_line && $first_line -lt $second_line ]] || fail "$description"
}

assert_line_equals() {
    local line_no=$1
    local expected=$2
    local actual=

    actual=${MENU_LINES[$((line_no - 1))]-__missing__}
    [[ $actual == "$expected" ]] || fail "line ${line_no} must be: $expected"
}

for file in sing-box.sh src/*.sh tests/*.sh; do
    [[ -e $REPO_ROOT/$file ]] || continue
    bash -n "$REPO_ROOT/$file"
done

assert_match '^is_sh_ver=v1\.27$' "$REPO_ROOT/sing-box.sh" \
    'sing-box.sh must keep the manager version at v1.27'
assert_match 'ui_title "sing-box 管理脚本" "\$is_sh_ver"' "$REPO_ROOT/src/core.sh" \
    'is_main_menu must keep the centered ui_title call'
assert_line_order 'ui_clear' 'ui_title "sing-box 管理脚本" "$is_sh_ver"' "$REPO_ROOT/src/core.sh" \
    'is_main_menu must clear before rendering ui_title'
assert_match 'ui_dim "\$\(build_main_status_line\)"' "$REPO_ROOT/src/core.sh" \
    'is_main_menu must keep the condensed status line'
assert_match 'ask mainmenu' "$REPO_ROOT/src/core.sh" \
    'is_main_menu must still delegate rendering to ask mainmenu'
assert_match 'case \$REPLY in' "$REPO_ROOT/src/core.sh" \
    'main menu dispatch must still use case $REPLY in'
assert_match 'is_opt_msg="请选择操作："' "$REPO_ROOT/src/core.sh" \
    'ask() mainmenu branch must define the main-menu guide line'
assert_match 'is_opt_input_msg="请输入选项编号（0 退出）： "' "$REPO_ROOT/src/core.sh" \
    'ask() mainmenu branch must define the main-menu prompt'
assert_contains '主菜单：输入 0 退出脚本。子菜单：输入 0 返回上一级。' "$REPO_ROOT/src/core.sh" \
    'main menu help line 1 must remain present'
assert_contains '普通输入：输入 q 取消当前操作。' "$REPO_ROOT/src/core.sh" \
    'main menu help line 2 must remain present'
assert_match '^ask_read_reply\(\)' "$REPO_ROOT/src/core.sh" \
    'ask() must route prompt input through ask_read_reply'
assert_match 'unset .*is_mainmenu_help' "$REPO_ROOT/src/core.sh" \
    'ask_cleanup() must clear the main-menu help flag'
assert_match 'ui_read_raw' "$REPO_ROOT/src/core.sh" \
    'ask_read_reply must use ui_read_raw when available'
assert_match '^preflight_anytls_acme\(\)' "$REPO_ROOT/src/core.sh" \
    'preflight_anytls_acme must remain present'
assert_match 'commit_server_config_with_validation' "$REPO_ROOT/src/core.sh" \
    'AnyTLS transactional config path must remain present'
assert_contains 'is_anytls_acme_port=443' "$REPO_ROOT/src/core.sh" \
    'AnyTLS ACME must keep TCP 443'
assert_match '^info\(\)' "$REPO_ROOT/src/core.sh" \
    'info output path must remain present'
assert_match '^url_qr\(\)' "$REPO_ROOT/src/core.sh" \
    'url/qr output path must remain present'

if ! bash -c '
    set -uo pipefail
    repo_root=$1
    # shellcheck disable=SC1091
    . "$repo_root/src/core.sh"

    ui_print() { printf "%b\n" "$*"; }
    ui_print_inline() { printf "%b" "$*"; }
    ui_blank() { printf "\n"; }
    ui_info() { printf "[i] %s\n" "$*"; }
    ui_error() { printf "[ERROR] %s\n" "$*" >&2; }
    ui_dim() { printf "%s\n" "$*"; }
    ui_clear() { :; }
    ui_title() {
        printf "sing-box 管理脚本\n"
        printf "Version: %s\n" "$2"
    }
    ui_menu_item() { printf " %2s. %s\n" "$1" "$2"; }
    ask_cleanup() {
        unset is_opt_msg is_opt_input_msg is_tmp_list is_ask_result is_default_arg is_emtpy_exit is_mainmenu_help
    }
    reset_menu_action_state() { :; }
    build_main_status_line() { printf "sing-box: active | Core: 1.13.8 | Caddy: inactive | Manager: systemd"; }

    is_sh_ver=v1.27
    is_main_start=
    is_menu_exit=
    is_menu_back=
    is_main_menu < <(printf "0\n")
' bash "$REPO_ROOT" >"$OUTPUT_FILE" 2>&1; then
    fail 'main menu mock render must complete without real services or root'
fi

MENU_LINES=()
while IFS= read -r line || [[ -n $line ]]; do
    MENU_LINES+=("$line")
done <"$OUTPUT_FILE"
[[ ${#MENU_LINES[@]} -eq 22 ]] || fail 'main menu mock render must keep the expected 22-line layout'

assert_line_equals 1 'sing-box 管理脚本'
assert_line_equals 2 'Version: v1.27'
assert_line_equals 3 'sing-box: active | Core: 1.13.8 | Caddy: inactive | Manager: systemd'
assert_line_equals 4 ''
assert_line_equals 5 '请选择操作：'
assert_line_equals 6 ''
assert_line_equals 7 '  1. 添加配置'
assert_line_equals 8 '  2. 更改配置'
assert_line_equals 9 '  3. 查看配置'
assert_line_equals 10 '  4. 删除配置'
assert_line_equals 11 '  5. 运行管理'
assert_line_equals 12 '  6. 更新'
assert_line_equals 13 '  7. 卸载'
assert_line_equals 14 '  8. 帮助'
assert_line_equals 15 '  9. 其他'
assert_line_equals 16 ' 10. 关于'
assert_line_equals 17 '  0. 退出'
assert_line_equals 18 ''
assert_line_equals 19 '主菜单：输入 0 退出脚本。子菜单：输入 0 返回上一级。'
assert_line_equals 20 '普通输入：输入 q 取消当前操作。'
assert_line_equals 21 ''
assert_line_equals 22 '请输入选项编号（0 退出）： '

printf '[PASS] main menu layout checks\n'
