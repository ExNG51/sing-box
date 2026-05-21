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

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

assert_match '^ui_section\(\)' "$REPO_ROOT/src/init.sh" \
    'src/init.sh must define ui_section'
assert_match 'ui_section "\$section"' "$REPO_ROOT/src/core.sh" \
    'confirm_menu_danger_token must use ui_section for danger confirmation sections'

for helper in ui_section ui_warn ui_kv ui_blank ui_confirm_token; do
    assert_match "^${helper}\\(\\)" "$REPO_ROOT/src/init.sh" \
        "src/init.sh must define $helper used by confirm_menu_danger_token"
done

output=$(bash -c '
    set -euo pipefail
    repo_root=$1
    definitions=$(awk "
        /^ui_print\(\)/,/^}/ { print }
        /^ui_blank\(\)/,/^}/ { print }
        /^ui_section\(\)/,/^}/ { print }
    " "$repo_root/src/init.sh")
    eval "$definitions"
    UI_STYLE_BOLD=
    UI_COLOR_BLUE=
    UI_COLOR_RESET=
    ui_section "危险操作确认"
' bash "$REPO_ROOT")

expected=$'\n>>> 危险操作确认'
[[ $output == "$expected" ]] || fail 'ui_section must output one leading blank line and the section title'

printf '[PASS] ui_section helper checks\n'
