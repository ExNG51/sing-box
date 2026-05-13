#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$REPO_ROOT/.github/workflows/release.yml"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
    printf '[FAIL] %s\n' "$1" >&2
    exit 1
}

assert_workflow_contains() {
    local pattern="$1"
    local description="$2"
    if ! grep -Eq "$pattern" "$WORKFLOW"; then
        fail "$description"
    fi
}

assert_workflow_not_contains() {
    local pattern="$1"
    local description="$2"
    if grep -Eq "$pattern" "$WORKFLOW"; then
        fail "$description"
    fi
}

assert_list_contains() {
    local pattern="$1"
    local description="$2"
    if ! grep -Eq "$pattern" "$TMP_DIR/list.txt"; then
        fail "$description"
    fi
}

assert_list_not_contains() {
    local pattern="$1"
    local description="$2"
    if grep -Eq "$pattern" "$TMP_DIR/list.txt"; then
        fail "$description"
    fi
}

assert_workflow_contains 'run: bash tests/release-package-scope\.sh' 'release workflow must check release package scope before packaging'
awk '
    /run: bash tests\/release-package-scope\.sh/ { check_line = NR }
    /- name: tar/ { tar_line = NR }
    END { exit !(check_line && tar_line && check_line < tar_line) }
' "$WORKFLOW" || fail 'release package scope checks must run before the tar step'

assert_workflow_not_contains 'tar zcvf code\.tar\.gz \./\*' 'release workflow must not package every root-level path'
assert_workflow_contains 'tar zcvf code\.tar\.gz LICENSE README\.md install\.sh sing-box\.sh src' 'release workflow must package only audited runtime files'

git -C "$REPO_ROOT" check-ignore -q audit-reports/example.md || fail 'audit-reports/ must be ignored as a process artifact'
git -C "$REPO_ROOT" check-ignore -q docs/example.md || fail 'docs/ must remain ignored as local documentation artifacts'
git -C "$REPO_ROOT" check-ignore -q code.tar.gz || fail 'local release artifacts must be ignored'
git -C "$REPO_ROOT" check-ignore -q .DS_Store || fail 'macOS metadata files must be ignored'

(
    cd "$REPO_ROOT"
    tar zcf "$TMP_DIR/code.tar.gz" LICENSE README.md install.sh sing-box.sh src
)
tar tzf "$TMP_DIR/code.tar.gz" >"$TMP_DIR/list.txt"

assert_list_contains '^install\.sh$' 'release package must include install.sh'
assert_list_contains '^sing-box\.sh$' 'release package must include sing-box.sh'
assert_list_contains '^src/backup\.sh$' 'release package must include src/backup.sh'
assert_list_contains '^src/core\.sh$' 'release package must include src/core.sh'
assert_list_contains '^src/init\.sh$' 'release package must include src/init.sh'
assert_list_contains '^src/version\.sh$' 'release package must include src/version.sh'

assert_list_not_contains '^\.github(/|$)' 'release package must not include GitHub workflow files'
assert_list_not_contains '^\.gitignore$' 'release package must not include git ignore metadata'
assert_list_not_contains '^tests(/|$)' 'release package must not include CI tests'
assert_list_not_contains '^audit-reports(/|$)' 'release package must not include audit reports'
assert_list_not_contains '^docs(/|$)' 'release package must not include local documentation artifacts'
assert_list_not_contains '^\.audit-tmp(/|$)' 'release package must not include local audit temp files'
assert_list_not_contains '^code\.tar\.gz$' 'release package must not include a nested release artifact'

printf '[PASS] release package scope checks\n'
