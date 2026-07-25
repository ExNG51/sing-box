#!/usr/bin/env bash
set -uo pipefail

# P2-07 regression: nested finalize pattern must not close an outer active transaction.
# Only the caller that began the transaction (should_finalize==true) may finalize it.
# Mirrors tests/rollback-current-transaction.sh harness style.

fail() {
    printf '[FAIL] %s\n' "$1" >&2
    exit 1
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/sb-txn-ownership.XXXXXX")"
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
IS_BACKUP_ROLLBACK_SKIP_SERVICES=true

err() { printf 'ERROR: %s\n' "$*" >&2; return 1; }
warn() { printf 'WARN: %s\n' "$*" >&2; }

# shellcheck disable=SC1091
. "$REPO_ROOT/src/backup.sh"

mkdir -p "$is_conf_dir" "$is_backup_dir"

# --- Scenario: outer opens txn, inner (nested) uses the finalize pattern, outer continues ---
init_backup_transaction op-outer
outer_dir=$IS_BACKUP_TXN_DIR
safe_write_file "$is_conf_dir/a.json" "A-content"

# Inner call mirrors the 4-site pattern: begin returns 1 (active), should_finalize=false.
inner_should_finalize=false
begin_backup_transaction_if_needed inner-op && inner_should_finalize=true
# The CORRECT (fixed) pattern: only finalize if this caller opened the txn.
[[ $inner_should_finalize == true ]] && finalize_backup_transaction

# Outer continues writing after inner returned.
safe_write_file "$is_conf_dir/b.json" "B-content"

# Assertions BEFORE finalize: inner must NOT have closed the outer transaction.
[[ ${IS_BACKUP_ACTIVE:-} == true ]] || fail "inner finalize must not close the outer transaction (IS_BACKUP_ACTIVE must stay true)"

finalize_backup_transaction

# Assertions AFTER finalize (manifest is written on finalize):
[[ -f "$outer_dir/manifest.json" ]] || fail "outer manifest must exist after finalize"
jq -e --arg p "$is_conf_dir/b.json" '.files[] | select(.path == $p) | .path' "$outer_dir/manifest.json" >/dev/null 2>&1 || fail "b.json must be recorded in the outer transaction manifest (not fragmented)"
jq -e --arg p "$is_conf_dir/a.json" '.files[] | select(.path == $p) | .path' "$outer_dir/manifest.json" >/dev/null 2>&1 || fail "a.json must still be in the outer transaction manifest"
txn_count=$(ls -1 "$is_backup_dir" | grep -c '^20' || true)
[[ $txn_count -eq 1 ]] || fail "expected exactly 1 txn dir, got $txn_count (fragmentation)"

# --- Contract: source must NOT retain the nesting-unaware clause at the 4 TUIC/hop sites ---
for site in "src/tuic.sh" "src/tuic_port_hopping.sh"; do
    bad=$(grep -c 'should_finalize == true || ${IS_BACKUP_ACTIVE' "$REPO_ROOT/$site" || true)
    [[ $bad -eq 0 ]] || fail "$site must not retain the nesting-unaware finalize clause"
done

# --- Contract: the fixed pattern (only should_finalize) must be present ---
tuic_commit_body=$(sed -n '/^tuic_commit_upsert()/,/^}/p' "$REPO_ROOT/src/tuic.sh")
[[ $tuic_commit_body == *'[[ $should_finalize == true ]] && finalize_backup_transaction'* ]] || \
    fail "tuic_commit_upsert must finalize only when should_finalize==true"

printf '[PASS] backup transaction ownership checks\n'
