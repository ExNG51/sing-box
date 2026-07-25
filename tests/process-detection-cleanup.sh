#!/usr/bin/env bash
set -uo pipefail

# Optimization Area 1: Process check cleanup & encapsulation.
# Verifies is_process_running helper behavior, unquoted pgrep checks removal,
# and proc fallback encapsulation.

fail() {
    printf '[FAIL] %s\n' "$1" >&2
    exit 1
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/sb-proc-clean.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

is_core=sing-box
is_core_dir="$TEST_ROOT/etc/sing-box"
is_conf_dir="$is_core_dir/conf"
is_config_json="$is_core_dir/config.json"
is_backup_dir="$is_core_dir/backups"
is_core_bin="$TEST_ROOT/usr/local/bin/sing-box"
is_sh_bin="$TEST_ROOT/usr/local/bin/sb"

err() { printf 'ERROR: %s\n' "$*" >&2; return 1; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
ui_warn() { warn "$*"; }
ui_print() { printf '%b\n' "$*"; }
ui_blank() { :; }
ui_kv() { :; }
ui_init_colors() { :; }

mkdir -p "$is_conf_dir" "$is_backup_dir"

eval "$(sed -n '/^is_process_running()/,/^}/p' "$REPO_ROOT/src/init.sh")"

# --- 1. Test is_process_running helper function exists and handles empty/invalid ---
type is_process_running >/dev/null 2>&1 || fail "is_process_running function must exist in src/init.sh"
is_process_running "" && fail "is_process_running must return 1 for empty bin" || true
is_process_running "nonexistent_proc_xyz_99999" && fail "is_process_running must return 1 for nonexistent process" || true

# --- 2. Static checks: unquoted pgrep and raw proc fallbacks outside helper ---
unquoted=$(grep -En 'pgrep -f \$' "$REPO_ROOT/src/init.sh" "$REPO_ROOT/src/core.sh" || true)
[[ -z "$unquoted" ]] || fail "src/ init.sh and core.sh must not contain unquoted pgrep -f \$ (found: $unquoted)"

raw_proc=$(grep -h '/proc/\*/cmdline' "$REPO_ROOT/src/init.sh" "$REPO_ROOT/src/core.sh" | wc -l | tr -d ' ')
[[ "$raw_proc" -eq 1 ]] || fail "src/ must encapsulate /proc/*/cmdline inside is_process_running (found count: $raw_proc)"

printf '[PASS] process detection cleanup checks\n'
