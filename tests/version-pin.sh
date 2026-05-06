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
        cat "$file" >&2
        fail "$description"
    }
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

err() {
    printf '%s\n' "$*" >&2
    return 1
}

msg() {
    printf '%s\n' "$*"
}

latest_called=0
get_latest_version() {
    latest_called=1
    : >"$TMP_ROOT/latest-called"
    latest_ver=v9.9.9
}

# shellcheck disable=SC1091
. "$REPO_ROOT/src/version.sh"

default_output="$TMP_ROOT/default.out"
selected="$(resolve_core_version_policy "" false 2>"$default_output")"
[[ $selected == "$DEFAULT_SING_BOX_STABLE_VERSION" ]] || fail 'default version policy must use DEFAULT_SING_BOX_STABLE_VERSION'
assert_contains "$default_output" "Using pinned stable sing-box version: $DEFAULT_SING_BOX_STABLE_VERSION" 'default version policy must explain stable pin'
[[ ! -e $TMP_ROOT/latest-called ]] || fail 'default version policy must not call latest release resolver'

latest_output="$TMP_ROOT/latest.out"
selected="$(resolve_core_version_policy "" true 2>"$latest_output")"
[[ $selected == v9.9.9 ]] || fail '--latest must use latest release resolver result'
assert_contains "$latest_output" "Using latest sing-box release. This may introduce breaking changes." '--latest must print breaking-change warning'
[[ -e $TMP_ROOT/latest-called ]] || fail '--latest must call latest release resolver'

explicit_output="$TMP_ROOT/explicit.out"
selected="$(resolve_core_version_policy "1.12.0" false 2>"$explicit_output")"
[[ $selected == v1.12.0 ]] || fail 'explicit version must be normalized and selected'
assert_contains "$explicit_output" "Using user-specified sing-box version: v1.12.0" 'explicit version policy must explain user-specified version'

if resolve_core_version_policy "v1.12.0" true >"$TMP_ROOT/conflict.out" 2>&1; then
    fail '--latest and --core-version must conflict'
fi
assert_contains "$TMP_ROOT/conflict.out" "Cannot use --latest and --core-version at the same time." 'conflict message must be explicit'

bash "$REPO_ROOT/install.sh" --help >"$TMP_ROOT/install-help.out" 2>&1 || true
assert_contains "$TMP_ROOT/install-help.out" "--latest" 'install help must mention --latest'
assert_contains "$TMP_ROOT/install-help.out" "pinned stable" 'install help must mention stable pin policy'

assert_contains "$REPO_ROOT/src/help.sh" "rollback" 'runtime help must mention rollback command'
assert_contains "$REPO_ROOT/src/help.sh" "--latest" 'runtime help must mention --latest for core update'
assert_contains "$REPO_ROOT/src/help.sh" "pinned stable" 'runtime help must mention stable pin policy'
assert_contains "$REPO_ROOT/.github/workflows/release.yml" "run: bash tests/version-pin.sh" 'release workflow must run version pin checks'
awk '
    /run: bash tests\/version-pin\.sh/ { check_line = NR }
    /- name: tar/ { tar_line = NR }
    END { exit !(check_line && tar_line && check_line < tar_line) }
' "$REPO_ROOT/.github/workflows/release.yml" || fail 'release workflow version pin checks must run before the tar step'

printf '[PASS] version pin checks\n'
