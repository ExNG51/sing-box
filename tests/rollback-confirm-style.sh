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
    grep -Fq -- "$text" "$file" || {
        printf '%s\n' "--- $file ---" >&2
        cat "$file" >&2
        fail "$description"
    }
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

warn() { printf 'WARN:%s\n' "$*" >&2; }
ui_warn() { printf '[WARN] %s\n' "$*" >&2; }
err() { printf 'ERROR:%s\n' "$*" >&2; return 1; }

# shellcheck disable=SC1091
. "$REPO_ROOT/src/backup.sh"

run_confirm() {
    local input=$1
    local name=$2
    local out="$TMP_DIR/$name.out"
    local err_file="$TMP_DIR/$name.err"
    local status

    set +e
    printf '%b' "$input" | rollback_confirm >"$out" 2>"$err_file"
    status=$?
    set -e
    printf '%s\n' "$status" >"$TMP_DIR/$name.status"
}

run_confirm "q\n" q
assert_contains "$TMP_DIR/q.out" '是否继续回滚？ [y/N，q 取消]: ' \
    'rollback confirmation prompt must use unified y/n/q wording'
assert_contains "$TMP_DIR/q.err" '[WARN] 已取消回滚。' \
    'q cancellation must warn on stderr'
[[ $(cat "$TMP_DIR/q.status") != 0 ]] || fail 'q cancellation must return non-zero'

run_confirm "\n" empty
assert_contains "$TMP_DIR/empty.err" '[WARN] 已取消回滚。' \
    'empty default cancellation must warn on stderr'
[[ $(cat "$TMP_DIR/empty.status") != 0 ]] || fail 'empty cancellation must return non-zero'

run_confirm "y\n" yes
assert_contains "$TMP_DIR/yes.out" '是否继续回滚？ [y/N，q 取消]: ' \
    'rollback confirmation must prompt before accepting yes'
[[ $(cat "$TMP_DIR/yes.status") == 0 ]] || fail 'y confirmation must return zero'

printf '[PASS] rollback confirmation style checks\n'
