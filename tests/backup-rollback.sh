#!/usr/bin/env bash
set -euo pipefail

fail() {
    printf '[FAIL] %s\n' "$1" >&2
    exit 1
}

assert_file_contains() {
    local file=$1
    local text=$2
    local description=$3
    grep -Fq -- "$text" "$file" || {
        cat "$file" >&2
        fail "$description"
    }
}

assert_file_not_contains() {
    local file=$1
    local text=$2
    local description=$3
    if grep -Fq -- "$text" "$file"; then
        cat "$file" >&2
        fail "$description"
    fi
}

assert_match_count() {
    local file=$1
    local text=$2
    local expected=$3
    local description=$4
    local count

    count=$(grep -Fc -- "$text" "$file" || true)
    [[ $count == "$expected" ]] || {
        cat "$file" >&2
        fail "$description: expected $expected, got $count"
    }
}

assert_exists() {
    [[ -e $1 || -L $1 ]] || fail "$2"
}

assert_not_exists() {
    [[ ! -e $1 && ! -L $1 ]] || fail "$2"
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

is_core=sing-box
is_core_name=sing-box
is_core_dir="$TEST_ROOT/etc/sing-box"
is_conf_dir="$is_core_dir/conf"
is_config_json="$is_core_dir/config.json"
is_backup_dir="$is_core_dir/backups"
is_caddy_dir="$TEST_ROOT/etc/caddy"
is_caddyfile="$is_caddy_dir/Caddyfile"
is_caddy_conf="$is_caddy_dir/conf"
is_core_bin="$TEST_ROOT/usr/local/bin/sing-box"
is_sh_bin="$TEST_ROOT/usr/local/bin/sb"
is_shell_profile="$TEST_ROOT/root/.bashrc"

is_systemd=
is_openrc=
IS_BACKUP_ROLLBACK_SKIP_SERVICES=true

err() {
    printf 'ERROR: %s\n' "$*" >&2
    return 1
}

warn() {
    printf 'WARN: %s\n' "$*" >&2
}

msg() {
    printf '%s\n' "$*"
}

# shellcheck disable=SC1091
. "$REPO_ROOT/src/backup.sh"

load_legacy_helpers_from_init() {
    local definitions

    definitions=$(awk '
        /^_rm\(\)/,/^}/ { print }
        /^_cp\(\)/,/^}/ { print }
        /^_sed\(\)/,/^}/ { print }
        /^_mkdir\(\)/,/^}/ { print }
    ' "$REPO_ROOT/src/init.sh")
    [[ $definitions == *"_rm()"* ]] || fail 'src/init.sh must expose legacy helper definitions'
    # shellcheck disable=SC1090
    eval "$definitions"
}

assert_shell_alias_management() {
    local profile=$is_shell_profile
    local latest_id manifest old_sh_bin

    mkdir -p "$(dirname "$profile")"
    printf 'export PATH="$PATH:/custom/bin"\n' >"$profile"

    init_backup_transaction alias-first-write
    safe_update_shell_aliases "$profile"
    safe_update_shell_aliases "$profile"
    finalize_backup_transaction

    assert_file_contains "$profile" 'export PATH="$PATH:/custom/bin"' 'alias update must preserve shell profile content outside the managed block'
    assert_match_count "$profile" '# >>> sing-box script aliases >>>' 1 'alias update must write one begin marker'
    assert_match_count "$profile" '# <<< sing-box script aliases <<<' 1 'alias update must write one end marker'
    assert_match_count "$profile" "alias sb='$is_sh_bin'" 1 'alias update must write one sb alias'
    assert_match_count "$profile" "alias $is_core='$is_sh_bin'" 1 'alias update must write one sing-box alias'

    latest_id="$(cat "$is_backup_dir/latest")"
    manifest="$is_backup_dir/$latest_id/manifest.json"
    assert_file_contains "$manifest" "\"path\":\"$profile\"" 'alias update manifest must record shell profile path'
    assert_exists "$is_backup_dir/$latest_id/root/.bashrc" 'alias update must snapshot existing shell profile'

    old_sh_bin=$is_sh_bin
    is_sh_bin="$TEST_ROOT/usr/local/bin/sing-box-new"
    init_backup_transaction alias-update-path
    safe_update_shell_aliases "$profile"
    finalize_backup_transaction
    assert_file_not_contains "$profile" "$old_sh_bin" 'alias update must remove the old managed alias target'
    assert_file_contains "$profile" "alias sb='$is_sh_bin'" 'alias update must write the new sb alias target'
    assert_file_contains "$profile" "alias $is_core='$is_sh_bin'" 'alias update must write the new sing-box alias target'
    assert_file_contains "$profile" 'export PATH="$PATH:/custom/bin"' 'alias path update must preserve shell profile content outside the managed block'
    is_sh_bin=$old_sh_bin

    init_backup_transaction alias-remove
    safe_remove_shell_aliases "$profile"
    finalize_backup_transaction
    assert_file_not_contains "$profile" '# >>> sing-box script aliases >>>' 'alias removal must delete begin marker'
    assert_file_not_contains "$profile" '# <<< sing-box script aliases <<<' 'alias removal must delete end marker'
    assert_file_not_contains "$profile" 'alias sb=' 'alias removal must delete managed sb alias'
    assert_file_not_contains "$profile" "alias $is_core=" 'alias removal must delete managed sing-box alias'
    assert_file_contains "$profile" 'export PATH="$PATH:/custom/bin"' 'alias removal must preserve shell profile content outside the managed block'

    printf 'export ORIGINAL_ALIAS_STATE=1\n' >"$profile"
    init_backup_transaction alias-rollback
    safe_update_shell_aliases "$profile"
    finalize_backup_transaction
    latest_id="$(cat "$is_backup_dir/latest")"
    manifest="$is_backup_dir/$latest_id/manifest.json"
    assert_file_contains "$manifest" "\"path\":\"$profile\"" 'alias rollback manifest must include shell profile path'
    rollback_latest_backup --yes >/tmp/backup-rollback-alias.out
    assert_file_contains "$profile" 'export ORIGINAL_ALIAS_STATE=1' 'rollback must restore shell profile content before alias update'
    assert_file_not_contains "$profile" '# >>> sing-box script aliases >>>' 'rollback must remove alias block created after backup'

    if grep -R 'sed -i "/$is_core/d" /root/.bashrc' "$REPO_ROOT/install.sh" "$REPO_ROOT/src" >/dev/null 2>&1; then
        fail 'uninstall must not delete /root/.bashrc aliases with a broad sed match'
    fi
    if grep -R '>>/root/.bashrc' "$REPO_ROOT/install.sh" "$REPO_ROOT/src" >/dev/null 2>&1; then
        fail 'install must not append aliases directly to /root/.bashrc'
    fi
}

assert_legacy_helpers_route_through_safe_ops() {
    local unsafe_path=$TEST_ROOT/home/user/custom-file
    local latest_id manifest
    local helper_file helper_src helper_dst helper_dir

    load_legacy_helpers_from_init

    mkdir -p "$(dirname "$unsafe_path")"
    printf 'do not remove\n' >"$unsafe_path"
    if _rm "$unsafe_path" >/tmp/backup-rollback-helper-rm.out 2>&1; then
        fail '_rm must reject unmanaged paths instead of deleting them directly'
    fi
    assert_exists "$unsafe_path" '_rm must leave unmanaged paths untouched'

    mkdir -p "$is_conf_dir"
    helper_file="$is_conf_dir/helper-sed.json"
    printf '{"name":"old"}\n' >"$helper_file"
    init_backup_transaction helper-sed
    _sed 's#old#new#' "$helper_file"
    finalize_backup_transaction
    assert_file_contains "$helper_file" '{"name":"new"}' '_sed must update the target file'
    latest_id="$(cat "$is_backup_dir/latest")"
    manifest="$is_backup_dir/$latest_id/manifest.json"
    assert_file_contains "$manifest" "\"path\":\"$helper_file\"" '_sed must record the modified file in the backup manifest'

    helper_src="$TEST_ROOT/source.json"
    helper_dst="$is_conf_dir/helper-copy.json"
    printf '{"copied":true}\n' >"$helper_src"
    init_backup_transaction helper-copy
    _cp "$helper_src" "$helper_dst"
    finalize_backup_transaction
    assert_file_contains "$helper_dst" '{"copied":true}' '_cp must copy file content'
    latest_id="$(cat "$is_backup_dir/latest")"
    manifest="$is_backup_dir/$latest_id/manifest.json"
    assert_file_contains "$manifest" "\"path\":\"$helper_dst\"" '_cp must record the destination in the backup manifest'

    helper_dir="$is_core_dir/helper-dir"
    init_backup_transaction helper-mkdir
    _mkdir "$helper_dir"
    finalize_backup_transaction
    assert_exists "$helper_dir" '_mkdir must create the directory'
    latest_id="$(cat "$is_backup_dir/latest")"
    manifest="$is_backup_dir/$latest_id/manifest.json"
    assert_file_contains "$manifest" "\"path\":\"$helper_dir\"" '_mkdir must record the created directory in the backup manifest'
}

assert_rejects_dangerous_remove_paths() {
    local candidate
    local status
    local dangerous_paths=(
        "__NO_ARGS__"
        ""
        "."
        ".."
        "/"
        "/etc"
        "/etc/"
        "/usr"
        "/usr/"
        "/lib"
        "/lib/"
        "/root"
        "/root/"
        "/var"
        "/var/"
        "/tmp"
        "/tmp/"
        "*"
        "relative/path"
        "./relative/path"
        "../relative/path"
        "$TEST_ROOT/etc/sing-box/../passwd"
        "$is_backup_dir"
        "$is_backup_dir/latest"
        "/home/user/file"
        "/opt/random/file"
    )

    for candidate in "${dangerous_paths[@]}"; do
        set +e
        (
            backup_calls="$TEST_ROOT/danger-backup-calls"
            rm_calls="$TEST_ROOT/danger-rm-calls"
            rm() {
                printf '%s\n' "$*" >>"$rm_calls"
                return 0
            }
            backup_path_before_write() {
                printf '%s\n' "$*" >>"$backup_calls"
                return 0
            }

            if [[ $candidate == "__NO_ARGS__" ]]; then
                if safe_remove_path; then
                    exit 10
                fi
            elif safe_remove_path "$candidate"; then
                exit 10
            fi
            [[ ! -e $backup_calls ]] || exit 11
            [[ ! -e $rm_calls ]] || exit 12
            [[ ! -d $is_backup_dir/unsafe-remove-test ]] || exit 13
        )
        status=$?
        set -e
        case $status in
        0) ;;
        10) fail "safe_remove_path must reject dangerous path: [$candidate]" ;;
        11) fail "safe_remove_path must reject before backup for dangerous path: [$candidate]" ;;
        12) fail "safe_remove_path must reject before rm for dangerous path: [$candidate]" ;;
        13) fail "safe_remove_path must not create backup transaction for dangerous path: [$candidate]" ;;
        *) fail "dangerous path test failed unexpectedly for [$candidate] with status $status" ;;
        esac
    done
}

assert_allows_managed_remove_paths() {
    local path
    local latest_id
    local allowed_manifest
    local allowed_paths=(
        "$is_config_json"
        "$is_conf_dir/test.json"
        "$is_caddyfile"
        "$is_caddy_conf/example.com.conf"
        "$is_caddy_conf/example.com.conf.add"
        "$TEST_ROOT/lib/systemd/system/sing-box.service"
        "$TEST_ROOT/etc/init.d/sing-box"
        "$TEST_ROOT/usr/local/bin/sb"
    )

    mkdir -p "$is_conf_dir" "$is_caddy_conf" "$TEST_ROOT/lib/systemd/system" "$TEST_ROOT/etc/init.d" "$TEST_ROOT/usr/local/bin"
    for path in "${allowed_paths[@]}"; do
        mkdir -p "$(dirname "$path")"
        printf 'managed remove test: %s\n' "$path" >"$path"
    done

    init_backup_transaction allow-remove
    for path in "${allowed_paths[@]}"; do
        safe_remove_path "$path" || fail "safe_remove_path must allow managed path: $path"
        assert_not_exists "$path" "safe_remove_path must delete managed path: $path"
    done
    finalize_backup_transaction

    latest_id="$(cat "$is_backup_dir/latest")"
    allowed_manifest="$is_backup_dir/$latest_id/manifest.json"
    assert_file_contains "$allowed_manifest" '"operation":"allow-remove"' 'allowed remove transaction must write manifest'
    for path in "${allowed_paths[@]}"; do
        assert_file_contains "$allowed_manifest" "\"path\":\"$path\"" "allowed remove manifest must record path: $path"
    done
}

assert_shell_alias_management
assert_legacy_helpers_route_through_safe_ops
assert_rejects_dangerous_remove_paths
assert_allows_managed_remove_paths

mkdir -p "$is_conf_dir" "$is_caddy_conf" "$TEST_ROOT/lib/systemd/system" "$TEST_ROOT/usr/local/bin"
printf '{"old":true}\n' >"$is_config_json"
printf '{"name":"old"}\n' >"$is_conf_dir/old.json"
printf 'old caddyfile\n' >"$is_caddyfile"
printf 'old service\n' >"$TEST_ROOT/lib/systemd/system/sing-box.service"

init_backup_transaction add
safe_write_file "$is_config_json" '{"new":true}'
safe_write_file "$is_conf_dir/new.json" '{"name":"new"}'
safe_remove_path "$is_conf_dir/old.json"
safe_write_file "$is_caddyfile" 'new caddyfile'
safe_write_file "$TEST_ROOT/lib/systemd/system/sing-box.service" 'new service'
finalize_backup_transaction

latest_id="$(cat "$is_backup_dir/latest")"
backup_txn="$is_backup_dir/$latest_id"
manifest="$backup_txn/manifest.json"

assert_exists "$manifest" 'backup transaction must write manifest.json'
assert_exists "$backup_txn/config.json" 'existing config.json must be copied before overwrite'
assert_exists "$backup_txn/conf/old.json" 'existing conf/*.json must be copied before delete'
assert_exists "$backup_txn/Caddyfile" 'existing Caddyfile must be copied before overwrite'
assert_exists "$backup_txn/lib/systemd/system/sing-box.service" 'existing service must be copied before overwrite'
assert_file_contains "$manifest" '"operation":"add"' 'manifest must record operation'
assert_file_contains "$manifest" "\"path\":\"$is_config_json\"" 'manifest must record config.json path'
assert_file_contains "$manifest" "\"path\":\"$is_conf_dir/new.json\"" 'manifest must record newly created file path'
assert_file_contains "$manifest" '"existed":true' 'manifest must record existed=true entries'
assert_file_contains "$manifest" '"existed":false' 'manifest must record existed=false entries'
[[ -s "$is_backup_dir/latest" ]] || fail 'latest pointer must point to newest backup'

before_dry_run="$(cat "$is_config_json")"
rollback_latest_backup --dry-run >/tmp/backup-rollback-dry-run.out
after_dry_run="$(cat "$is_config_json")"
[[ $before_dry_run == "$after_dry_run" ]] || fail 'rollback --dry-run must not modify files'

rollback_latest_backup --yes >/tmp/backup-rollback-run.out
assert_file_contains "$is_config_json" '{"old":true}' 'rollback must restore previous config.json'
assert_exists "$is_conf_dir/old.json" 'rollback must restore deleted conf/*.json'
assert_not_exists "$is_conf_dir/new.json" 'rollback must delete manifest existed=false files'
assert_file_contains "$is_caddyfile" 'old caddyfile' 'rollback must restore previous Caddyfile'
assert_file_contains "$TEST_ROOT/lib/systemd/system/sing-box.service" 'old service' 'rollback must restore previous service'

rollback_id="$(cat "$is_backup_dir/latest")"
rollback_manifest="$is_backup_dir/$rollback_id/manifest.json"
assert_file_contains "$rollback_manifest" '"operation":"pre-rollback"' 'rollback must create a pre-rollback transaction'

cat >"$is_backup_dir/latest" <<<"$latest_id"
rm -f "$backup_txn/config.json"
if rollback_latest_backup --yes >/tmp/backup-rollback-missing.out 2>&1; then
    fail 'rollback must refuse when a backup file is missing'
fi

printf 'not json\n' >"$manifest"
if rollback_latest_backup --yes >/tmp/backup-rollback-bad-manifest.out 2>&1; then
    fail 'rollback must refuse when manifest is damaged'
fi

assert_file_contains "$REPO_ROOT/.github/workflows/release.yml" "for file in tests/*.sh" 'release workflow must run full local test matrix'
awk '
    /for file in tests\/\*\.sh/ { check_line = NR }
    /- name: tar/ { tar_line = NR }
    END { exit !(check_line && tar_line && check_line < tar_line) }
' "$REPO_ROOT/.github/workflows/release.yml" || fail 'release workflow local test matrix must run before the tar step'

printf '[PASS] backup and rollback checks\n'
