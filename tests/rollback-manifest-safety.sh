#!/usr/bin/env bash
set -euo pipefail

fail() {
    printf '[FAIL] %s\n' "$1" >&2
    exit 1
}

assert_rejects_path() {
    local path=$1
    local description=$2

    if validate_rollback_manifest_path "$path" false >/tmp/rollback-manifest-safety.out 2>&1; then
        fail "$description"
    fi
}

assert_allows_path() {
    local path=$1
    local description=$2

    validate_rollback_manifest_path "$path" false >/tmp/rollback-manifest-safety.out 2>&1 || fail "$description"
}

write_manifest() {
    local txn_dir=$1
    local path=$2
    local existed=$3
    local backup_path=${4:-}

    mkdir -p "$txn_dir"
    cat >"$txn_dir/manifest.json" <<JSON
{
  "schema_version":1,
  "created_at":"2026-05-21T00:00:00Z",
  "operation":"manifest-safety",
  "script_repo":"ExNG51/sing-box",
  "script_version":"test",
  "sing_box_version_before":"test",
  "sing_box_version_after":null,
  "init_system":"test",
  "files":[
    {"path":"$path","backup_path":$backup_path,"type":"missing","existed":$existed,"sha256_before":null}
  ]
}
JSON
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/sing-box-manifest-safety.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

is_core=sing-box
is_core_name=sing-box
is_core_dir="$TEST_ROOT/etc/sing-box"
is_conf_dir="$is_core_dir/conf"
is_config_json="$is_core_dir/config.json"
is_backup_dir="$is_core_dir/backups"
is_caddyfile="$TEST_ROOT/etc/caddy/Caddyfile"
is_caddy_conf="$TEST_ROOT/etc/caddy/conf"
is_core_bin="$TEST_ROOT/usr/local/bin/sing-box"
is_sh_bin="$TEST_ROOT/usr/local/bin/sb"
is_shell_profile="$TEST_ROOT/root/.bashrc"
TUIC_HOP_INSTANCE_DIR="$TEST_ROOT/etc/tuic-port-hopping/instances"
TUIC_HOP_NFT_RULE_DIR="$TEST_ROOT/etc/nftables.d"
TUIC_HOP_APPLY_SCRIPT="$TEST_ROOT/usr/local/sbin/apply-tuic-port-hopping.sh"
TUIC_HOP_SYSTEMD_TEMPLATE="$TEST_ROOT/etc/systemd/system/tuic-port-hopping@.service"
IS_BACKUP_ROLLBACK_SKIP_SERVICES=true

err() {
    printf 'ERROR: %s\n' "$*" >&2
    return 1
}

warn() {
    printf 'WARN: %s\n' "$*" >&2
}

# shellcheck disable=SC1091
. "$REPO_ROOT/src/backup.sh"

type validate_rollback_manifest_path >/dev/null 2>&1 || fail 'validate_rollback_manifest_path must exist'

assert_rejects_path '/etc/passwd' 'rollback manifest must reject /etc/passwd'
assert_rejects_path '/etc' 'rollback manifest must reject broad /etc'
assert_rejects_path '/etc/nftables.d' 'rollback manifest must reject broad nftables directory'
assert_allows_path "$TUIC_HOP_INSTANCE_DIR/443.env" 'rollback manifest must allow managed hop env files'
assert_allows_path "$is_conf_dir/tuic.json" 'rollback manifest must allow managed sing-box config fragments'
assert_allows_path "$TUIC_HOP_SYSTEMD_TEMPLATE" 'rollback manifest must allow managed hop systemd template'

mkdir -p "$is_backup_dir"
printf 'old-latest\n' >"$is_backup_dir/latest"
unsafe_txn="$is_backup_dir/unsafe"
write_manifest "$unsafe_txn" '/etc/passwd' false null
printf 'unsafe\n' >"$TEST_ROOT/rm-called"

(
    trap - EXIT
    rm() {
        printf '%s\n' "$*" >>"$TEST_ROOT/rm-called"
        return 0
    }
    if rollback_backup_transaction_dir "$unsafe_txn" --yes >"$TEST_ROOT/unsafe-rollback.out" 2>&1; then
        exit 10
    fi
)
status=$?
case $status in
0) ;;
10) fail 'rollback must reject unsafe manifest before applying it' ;;
*) fail "unsafe rollback exited unexpectedly with $status" ;;
esac
(( $(wc -l <"$TEST_ROOT/rm-called") == 1 )) || fail 'unsafe rollback must not execute rm -rf'

safe_txn="$is_backup_dir/safe"
mkdir -p "$TUIC_HOP_INSTANCE_DIR" "$safe_txn/etc/tuic-port-hopping/instances"
printf 'mutated\n' >"$TUIC_HOP_INSTANCE_DIR/443.env"
printf 'original\n' >"$safe_txn/etc/tuic-port-hopping/instances/443.env"
write_manifest "$safe_txn" "$TUIC_HOP_INSTANCE_DIR/443.env" true '"etc/tuic-port-hopping/instances/443.env"'
rollback_backup_transaction_dir "$safe_txn" --yes >"$TEST_ROOT/safe-rollback.out"
[[ $(cat "$TUIC_HOP_INSTANCE_DIR/443.env") == original ]] || fail 'safe manifest rollback must restore allowed hop env'

printf '[PASS] rollback manifest safety checks\n'
