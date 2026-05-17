#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sing-box-ask-list-layout.XXXXXX")"
LIST_OUTPUT_FILE="$TMP_DIR/ask-list.out"
EMPTY_OUTPUT_FILE="$TMP_DIR/ask-list-empty.out"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
    printf '[FAIL] %s\n' "$1" >&2
    for file in "$LIST_OUTPUT_FILE" "$EMPTY_OUTPUT_FILE"; do
        [[ -f $file ]] || continue
        printf '%s\n' "--- captured output: $(basename "$file") ---" >&2
        cat "$file" >&2
        printf '%s\n' '-----------------------' >&2
    done
    exit 1
}

assert_contains() {
    local text=$1
    local file=$2
    local description=$3

    grep -Fq -- "$text" "$file" || fail "$description"
}

assert_single_blank_before_prompt() {
    local file=$1
    local item_line=$2
    local prompt_line=$3
    local item_index=
    local lines=()

    while IFS= read -r line || [[ -n $line ]]; do
        lines+=("$line")
    done <"$file"

    for i in "${!lines[@]}"; do
        if [[ ${lines[$i]} == "$item_line" ]]; then
            item_index=$i
            break
        fi
    done

    [[ ${item_index:-} ]] || fail "menu item line must be captured: $item_line"
    [[ ${lines[$((item_index + 1))]-__missing__} == '' ]] || \
        fail "menu item must be followed by exactly one blank line: $item_line"
    [[ ${lines[$((item_index + 2))]-} == "$prompt_line"* ]] || \
        fail "prompt must immediately follow the single blank line after menu item: $item_line"
}

for file in sing-box.sh src/*.sh tests/*.sh; do
    [[ -e $REPO_ROOT/$file ]] || continue
    bash -n "$REPO_ROOT/$file"
done

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
    ui_menu_item() { printf " %2s. %s\n" "$1" "$2"; }

    is_all_json=("AnyTLS-example.json" "TUIC-21428.json")
    is_main_start=1
    ask get_config_file < <(printf "0\n")
    printf "status=%s\n" "$?"
' bash "$REPO_ROOT" >"$LIST_OUTPUT_FILE" 2>&1; then
    fail 'get_config_file list mock render must complete without real services or root'
fi

assert_contains '请选择配置:' "$LIST_OUTPUT_FILE" \
    'configuration list title must be present'
assert_contains '  1. AnyTLS-example.json' "$LIST_OUTPUT_FILE" \
    'configuration list item 1 must be present'
assert_contains '  2. TUIC-21428.json' "$LIST_OUTPUT_FILE" \
    'configuration list item 2 must be present'
assert_contains '  0. 返回主菜单' "$LIST_OUTPUT_FILE" \
    'configuration list must include the menu-back option'
assert_contains '请输入选项编号（0 返回，1-2）： ' "$LIST_OUTPUT_FILE" \
    'configuration list prompt must be present'
assert_single_blank_before_prompt \
    "$LIST_OUTPUT_FILE" \
    '  0. 返回主菜单' \
    '请输入选项编号（0 返回，1-2）： '

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
    ui_menu_item() { printf " %2s. %s\n" "$1" "$2"; }

    set +u
    declare -a is_all_json=()
    is_main_start=1
    ask get_config_file < <(printf "0\n")
    printf "status=%s\n" "$?"
' bash "$REPO_ROOT" >"$EMPTY_OUTPUT_FILE" 2>&1; then
    fail 'empty get_config_file list mock render must complete without real services or root'
fi

assert_contains '请选择配置:' "$EMPTY_OUTPUT_FILE" \
    'empty configuration list title must be present'
assert_contains '  0. 返回主菜单' "$EMPTY_OUTPUT_FILE" \
    'empty configuration list must include the menu-back option'
assert_contains '请输入选项编号（0 返回）： ' "$EMPTY_OUTPUT_FILE" \
    'empty configuration list prompt must be present'
assert_single_blank_before_prompt \
    "$EMPTY_OUTPUT_FILE" \
    '  0. 返回主菜单' \
    '请输入选项编号（0 返回）： '

printf '[PASS] ask list layout checks\n'
