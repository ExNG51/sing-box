#!/usr/bin/env bash
set -uo pipefail

# P2-01: caddy_conf directory creation must go through safe_ensure_dir (in manifest, rollback-safe),
# and rollback must allow the exact caddy_conf dir (empty-dir-only delete, preserve user configs).
# Mirrors tests/rollback-current-transaction.sh harness style.

fail() {
    printf '[FAIL] %s\n' "$1" >&2
    exit 1
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/sb-caddy-rollback.XXXXXX")"
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
IS_BACKUP_ROLLBACK_SKIP_SERVICES=true

err() { printf 'ERROR: %s\n' "$*" >&2; return 1; }
warn() { printf 'WARN: %s\n' "$*" >&2; }

# shellcheck disable=SC1091
. "$REPO_ROOT/src/backup.sh"
# shellcheck disable=SC1091
. "$REPO_ROOT/src/caddy.sh"

mkdir -p "$is_conf_dir" "$is_backup_dir" "$is_caddy_dir"

# --- Scenario 0 (integration): caddy_config new records all dirs and rollback succeeds ---
host="example.com"
is_http_port=80
is_https_port=443
init_backup_transaction caddy-new
caddy_config new >/dev/null 2>&1 || true
finalize_backup_transaction
caddy_txn=$IS_LAST_BACKUP_TXN_DIR
[[ -f "$caddy_txn/manifest.json" ]] || fail "caddy_config new must record writes in manifest"
# all three dirs must be allowlisted for rollback
for d in "$is_caddy_conf" "$is_caddy_dir" "$is_caddy_dir/sites" "$is_caddyfile"; do
    jq -e --arg p "$d" '.files[] | select(.path == $p) | .path' "$caddy_txn/manifest.json" >/dev/null 2>&1 || \
        fail "caddy_config new must record $d in manifest"
done
# rollback must NOT error on any caddy path
rollback_backup_transaction_dir "$caddy_txn" --yes >/dev/null 2>&1 || fail "rollback must succeed after caddy_config new (all dirs allowlisted)"

# --- Scenario 1: caddy_conf created via safe_ensure_dir, recorded in finalized manifest ---
init_backup_transaction create-caddy
safe_ensure_dir "$is_caddy_conf"
finalize_backup_transaction
[[ -f "$IS_LAST_BACKUP_TXN_DIR/manifest.json" ]] || fail "caddy txn manifest must exist"
jq -e --arg p "$is_caddy_conf" '.files[] | select(.path == $p) | .path' "$IS_LAST_BACKUP_TXN_DIR/manifest.json" >/dev/null 2>&1 || \
    fail "caddy_conf must be recorded in finalized manifest"

# --- Scenario 2: rollback of a newly-created caddy_conf dir (empty) removes it ---
init_backup_transaction create-caddy2
safe_ensure_dir "$is_caddy_conf"   # existed=false now (created above), re-recorded
finalize_backup_transaction
rollback_backup_transaction_dir "$IS_LAST_BACKUP_TXN_DIR" --yes >/dev/null 2>&1 || fail "rollback must succeed for caddy_conf dir"
# After rollback, caddy_conf dir may be restored to its prior state (empty dir existed from scenario1).
# The key assertion: rollback did not error out on the caddy_conf path (allowlist accepted it).

# --- Scenario 3: caddy_conf with user config preserved on rollback of a re-init ---
mkdir -p "$is_caddy_conf"
printf 'user-site.conf content\n' >"$is_caddy_conf/existing.conf"
init_backup_transaction create-caddy3
# existed=true now; rollback would restore. Test that a NEW dir (existed=false) with content is preserved.
rm -rf "$is_caddy_conf"
safe_ensure_dir "$is_caddy_conf"
printf 'new-site.conf content\n' >"$is_caddy_conf/new.conf"   # user-added after creation
finalize_backup_transaction
rollback_backup_transaction_dir "$IS_LAST_BACKUP_TXN_DIR" --yes >/dev/null 2>&1 || fail "rollback must not error on non-empty caddy_conf"
# The non-empty dir should be preserved (rmdir fails gracefully), new.conf kept.
[[ -f "$is_caddy_conf/new.conf" ]] || fail "rollback must preserve user configs in non-empty caddy_conf dir"

# --- Contract: source must not use bare mkdir for caddy_conf ---
caddy_sh="$REPO_ROOT/src/caddy.sh"
core_sh="$REPO_ROOT/src/core.sh"
grep -q 'mkdir -p .*\$is_caddy_conf' "$caddy_sh" && fail "src/caddy.sh must not use bare mkdir for is_caddy_conf" || true
grep -q 'mkdir -p \$is_caddy_conf' "$core_sh" && fail "src/core.sh must not use bare mkdir for is_caddy_conf" || true
grep -q 'safe_ensure_dir "$is_caddy_conf"' "$caddy_sh" || fail "src/caddy.sh must use safe_ensure_dir for is_caddy_conf"
grep -q 'safe_ensure_dir "$is_caddy_conf"' "$core_sh" || fail "src/core.sh must use safe_ensure_dir for is_caddy_conf"

# --- Contract: is_managed_rollback_path must allow exact caddy_conf dir ---
grep -q '\[\[ $path == "$caddy_conf" \]\] && return 0' "$REPO_ROOT/src/backup.sh" || \
    fail "is_managed_rollback_path must allow exact caddy_conf dir for rollback"

printf '[PASS] create caddy rollback checks\n'
