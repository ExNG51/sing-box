#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sing-box-ask-list-layout.XXXXXX")"
OUTPUT_FILE="$TMP_DIR/ask-list.out"
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
' bash "$REPO_ROOT" >"$OUTPUT_FILE" 2>&1; then
    fail 'get_config_file list mock render must complete without real services or root'
fi

assert_contains '请选择配置:' "$OUTPUT_FILE" \
    'configuration list title must be present'
assert_contains '  1. AnyTLS-example.json' "$OUTPUT_FILE" \
    'configuration list item 1 must be present'
assert_contains '  2. TUIC-21428.json' "$OUTPUT_FILE" \
    'configuration list item 2 must be present'
assert_contains '  0. 返回主菜单' "$OUTPUT_FILE" \
    'configuration list must include the menu-back option'
assert_contains '请输入选项编号（0 返回，1-2）： ' "$OUTPUT_FILE" \
    'configuration list prompt must be present'

ASK_LINES=()
while IFS= read -r line || [[ -n $line ]]; do
    ASK_LINES+=("$line")
done <"$OUTPUT_FILE"
back_line_index=
for i in "${!ASK_LINES[@]}"; do
    if [[ ${ASK_LINES[$i]} == '  0. 返回主菜单' ]]; then
        back_line_index=$i
        break
    fi
done

[[ ${back_line_index:-} ]] || fail 'menu-back option line must be captured'
blank_line_index=$((back_line_index + 1))
prompt_line_index=$((back_line_index + 2))

[[ ${ASK_LINES[$blank_line_index]-__missing__} == '' ]] || \
    fail 'menu-back option must be followed by exactly one blank line'
[[ ${ASK_LINES[$prompt_line_index]-} == 请输入选项编号（0\ 返回，1-2）：\ * ]] || \
    fail 'prompt must immediately follow the single blank line after menu-back option'

printf '[PASS] ask list layout checks\n'
