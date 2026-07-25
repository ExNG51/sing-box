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
        printf -- '--- %s ---\n' "$file" >&2
        cat "$file" >&2
        fail "$description"
    }
}

assert_file_not_contains() {
    local file=$1
    local text=$2
    local description=$3
    if grep -Fq -- "$text" "$file"; then
        printf -- '--- %s ---\n' "$file" >&2
        cat "$file" >&2
        fail "$description"
    fi
}

assert_exists() {
    [[ -e $1 || -L $1 ]] || fail "$2"
}

assert_not_exists() {
    [[ ! -e $1 && ! -L $1 ]] || fail "$2"
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
AUDIT_DIR="$REPO_ROOT/.audit-tmp"
mkdir -p "$AUDIT_DIR"
TEST_ROOT="$(mktemp -d "$AUDIT_DIR/mock-backup-root.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT
LOG="$AUDIT_DIR/mock-backup-rollback.log"
: >"$LOG"

exec >>"$LOG" 2>&1

is_core=sing-box
is_core_name=sing-box
is_core_dir="$TEST_ROOT/etc/sing-box"
is_conf_dir="$is_core_dir/conf"
is_config_json="$is_core_dir/config.json"
is_backup_dir="$is_core_dir/backups"
is_core_bin="$is_core_dir/bin/sing-box"
is_sh_dir="$is_core_dir/sh"
is_sh_bin="$TEST_ROOT/usr/local/bin/sing-box"
is_shell_profile="$TEST_ROOT/root/.bashrc"
is_log_dir="$TEST_ROOT/var/log/sing-box"
is_caddy_dir="$TEST_ROOT/etc/caddy"
is_caddyfile="$is_caddy_dir/Caddyfile"
is_caddy_conf="$is_caddy_dir/conf"
is_caddy_bin="$TEST_ROOT/usr/local/bin/caddy"
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

mkdir -p "$is_conf_dir" "$is_core_dir/bin" "$is_caddy_conf" "$TEST_ROOT/usr/local/bin" \
    "$TEST_ROOT/lib/systemd/system" "$TEST_ROOT/etc/systemd/system" "$TEST_ROOT/etc/init.d" \
    "$TEST_ROOT/root" "$is_log_dir" "$is_sh_dir"
printf 'export PATH="$PATH:/custom/bin"\n' >"$is_shell_profile"

# shellcheck disable=SC1091
. "$REPO_ROOT/src/backup.sh"

load_legacy_helpers_from_init

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
assert_exists "$backup_txn/config.json" 'overwrite must back up old config.json'
assert_exists "$backup_txn/conf/old.json" 'delete must back up old conf json'
assert_exists "$backup_txn/Caddyfile" 'overwrite must back up Caddyfile'
assert_exists "$backup_txn/lib/systemd/system/sing-box.service" 'overwrite must back up service file'
assert_file_contains "$manifest" '"operation":"add"' 'manifest must record operation'
assert_file_contains "$manifest" "\"path\":\"$is_config_json\"" 'manifest must record config path'
assert_file_contains "$manifest" "\"path\":\"$is_conf_dir/new.json\"" 'manifest must record new file'
assert_file_contains "$manifest" '"existed":true' 'manifest must include existed=true'
assert_file_contains "$manifest" '"existed":false' 'manifest must include existed=false'

before_dry_run="$(cat "$is_config_json")"
rollback_latest_backup --dry-run >"$TEST_ROOT/rollback-dry-run.out"
after_dry_run="$(cat "$is_config_json")"
[[ $before_dry_run == "$after_dry_run" ]] || fail 'rollback --dry-run must not change files'

rollback_latest_backup --yes >"$TEST_ROOT/rollback-run.out"
assert_file_contains "$is_config_json" '{"old":true}' 'rollback must restore config'
assert_exists "$is_conf_dir/old.json" 'rollback must restore deleted config'
assert_not_exists "$is_conf_dir/new.json" 'rollback must delete existed=false file'
assert_file_contains "$is_caddyfile" 'old caddyfile' 'rollback must restore Caddyfile'
assert_file_contains "$TEST_ROOT/lib/systemd/system/sing-box.service" 'old service' 'rollback must restore service'

rollback_id="$(cat "$is_backup_dir/latest")"
rollback_manifest="$is_backup_dir/$rollback_id/manifest.json"
assert_file_contains "$rollback_manifest" '"operation":"pre-rollback"' 'rollback must create pre-rollback transaction'

printf '%s\n' "$latest_id" >"$is_backup_dir/latest"
rm -f "$backup_txn/config.json"
if rollback_latest_backup --yes >"$TEST_ROOT/rollback-missing.out" 2>&1; then
    fail 'rollback must reject missing backup files'
fi

printf 'not json\n' >"$manifest"
if rollback_latest_backup --yes >"$TEST_ROOT/rollback-bad-manifest.out" 2>&1; then
    fail 'rollback must reject damaged manifest'
fi

dangerous_paths=(
    "__NO_ARGS__"
    ""
    "."
    ".."
    "/"
    "/etc"
    "/usr"
    "/lib"
    "/root"
    "/var"
    "/tmp"
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

for remove_target_path in "${dangerous_paths[@]}"; do
    set +e
    if [[ $remove_target_path == "__NO_ARGS__" ]]; then
        safe_remove_path >"$TEST_ROOT/remove-danger.out" 2>&1
    else
        safe_remove_path "$remove_target_path" >"$TEST_ROOT/remove-danger.out" 2>&1
    fi
    status=$?
    set -e
    [[ $status -ne 0 ]] || fail "dangerous path accepted: $remove_target_path"
done

allowed_paths=(
    "$is_config_json"
    "$is_conf_dir/test.json"
    "$is_caddyfile"
    "$is_caddy_conf/example.com.conf"
    "$is_caddy_conf/example.com.conf.add"
    "$TEST_ROOT/lib/systemd/system/sing-box.service"
    "$TEST_ROOT/etc/init.d/sing-box"
    "$TEST_ROOT/usr/local/bin/sb"
)

for remove_target_path in "${allowed_paths[@]}"; do
    mkdir -p "$(dirname "$remove_target_path")"
    printf 'managed remove test\n' >"$remove_target_path"
done

init_backup_transaction allow-remove
for remove_target_path in "${allowed_paths[@]}"; do
    safe_remove_path "$remove_target_path"
    assert_not_exists "$remove_target_path" "managed path must be removed: $remove_target_path"
done
finalize_backup_transaction

allowed_id="$(cat "$is_backup_dir/latest")"
allowed_manifest="$is_backup_dir/$allowed_id/manifest.json"
for remove_target_path in "${allowed_paths[@]}"; do
    assert_file_contains "$allowed_manifest" "\"path\":\"$remove_target_path\"" "managed remove must be recorded: $remove_target_path"
done

printf 'export PATH="$PATH:/custom/bin"\n' >"$is_shell_profile"

init_backup_transaction alias-first-write
safe_update_shell_aliases "$is_shell_profile"
safe_update_shell_aliases "$is_shell_profile"
finalize_backup_transaction

assert_file_contains "$is_shell_profile" 'export PATH="$PATH:/custom/bin"' 'alias update must preserve external content'
[[ "$(grep -Fc '# >>> sing-box script aliases >>>' "$is_shell_profile")" == 1 ]] || fail 'alias begin marker must be idempotent'
[[ "$(grep -Fc '# <<< sing-box script aliases <<<' "$is_shell_profile")" == 1 ]] || fail 'alias end marker must be idempotent'
assert_file_contains "$is_shell_profile" "alias sb='$is_sh_bin'" 'alias block must include sb'
assert_file_contains "$is_shell_profile" "alias $is_core='$is_sh_bin'" 'alias block must include core alias'

old_sh_bin="$is_sh_bin"
is_sh_bin="$TEST_ROOT/usr/local/bin/sing-box-new"
init_backup_transaction alias-update-path
safe_update_shell_aliases "$is_shell_profile"
finalize_backup_transaction
assert_file_not_contains "$is_shell_profile" "alias sb='$old_sh_bin'" 'alias update must remove old sb target'
assert_file_not_contains "$is_shell_profile" "alias $is_core='$old_sh_bin'" 'alias update must remove old core target'
assert_file_contains "$is_shell_profile" "alias sb='$is_sh_bin'" 'alias update must write new sb target'
assert_file_contains "$is_shell_profile" "alias $is_core='$is_sh_bin'" 'alias update must write new core target'
assert_file_contains "$is_shell_profile" 'export PATH="$PATH:/custom/bin"' 'alias update must preserve external content after target change'
is_sh_bin="$old_sh_bin"

init_backup_transaction alias-remove
safe_remove_shell_aliases "$is_shell_profile"
finalize_backup_transaction
assert_file_not_contains "$is_shell_profile" '# >>> sing-box script aliases >>>' 'alias remove must delete begin marker'
assert_file_not_contains "$is_shell_profile" '# <<< sing-box script aliases <<<' 'alias remove must delete end marker'
assert_file_not_contains "$is_shell_profile" 'alias sb=' 'alias remove must delete sb alias'
assert_file_contains "$is_shell_profile" 'export PATH="$PATH:/custom/bin"' 'alias remove must preserve external content'

printf 'export ORIGINAL_ALIAS_STATE=1\n' >"$is_shell_profile"
init_backup_transaction alias-rollback
safe_update_shell_aliases "$is_shell_profile"
finalize_backup_transaction
rollback_latest_backup --yes >"$TEST_ROOT/rollback-alias.out"
assert_file_contains "$is_shell_profile" 'export ORIGINAL_ALIAS_STATE=1' 'rollback must restore alias pre-state'
assert_file_not_contains "$is_shell_profile" '# >>> sing-box script aliases >>>' 'rollback must remove alias block created after backup'

if grep -RInE '>>/root/\.bashrc' "$REPO_ROOT/install.sh" "$REPO_ROOT/src" >/dev/null 2>&1; then
    fail 'must not append directly to /root/.bashrc'
fi
if grep -RInE 'sed[[:space:]]+-i[[:space:]].*/\$is_core/d.*/root/\.bashrc' "$REPO_ROOT/install.sh" "$REPO_ROOT/src" >/dev/null 2>&1; then
    fail 'must not broad sed delete /root/.bashrc aliases'
fi

unsafe_path="$TEST_ROOT/home/user/custom-file"
mkdir -p "$(dirname "$unsafe_path")"
printf 'do not remove\n' >"$unsafe_path"
if _rm "$unsafe_path" >"$TEST_ROOT/legacy-rm.out" 2>&1; then
    fail '_rm must reject unmanaged paths'
fi
assert_exists "$unsafe_path" '_rm must not delete unmanaged path'

helper_file="$is_conf_dir/helper-sed.json"
printf '{"name":"old"}\n' >"$helper_file"
init_backup_transaction helper-sed
_sed 's#old#new#' "$helper_file"
finalize_backup_transaction
assert_file_contains "$helper_file" '{"name":"new"}' '_sed must modify through safe wrapper'

helper_src="$TEST_ROOT/source.json"
helper_dst="$is_conf_dir/helper-copy.json"
printf '{"copied":true}\n' >"$helper_src"
init_backup_transaction helper-copy
_cp "$helper_src" "$helper_dst"
finalize_backup_transaction
assert_file_contains "$helper_dst" '{"copied":true}' '_cp must copy through safe wrapper'

helper_dir="$is_core_dir/helper-dir"
init_backup_transaction helper-mkdir
_mkdir "$helper_dir"
finalize_backup_transaction
assert_exists "$helper_dir" '_mkdir must create through safe wrapper'

printf '[PASS] mock backup/rollback audit root: %s\n' "$TEST_ROOT"
