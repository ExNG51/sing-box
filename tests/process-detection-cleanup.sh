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

# --- 2. Test is_process_running with a mocked pgrep present on PATH ---
mock_pgrep_dir="$TEST_ROOT/mock-pgrep"
mkdir -p "$mock_pgrep_dir"
printf '%s\n' \
    '#!/bin/sh' \
    'if [ "${1:-}" = "-f" ] && [ "${2:-}" = "sentinel_running_test" ]; then' \
    '    exit 0' \
    'fi' \
    'exit 1' > "$mock_pgrep_dir/pgrep"
chmod +x "$mock_pgrep_dir/pgrep"

(
    PATH="$mock_pgrep_dir:$PATH"
    is_process_running "sentinel_running_test"
) || fail "is_process_running must return 0 when mocked pgrep finds a process"

# --- 3. Test is_process_running fallback when pgrep is absent from PATH ---
mock_fallback_dir="$TEST_ROOT/mock-fallback"
mkdir -p "$mock_fallback_dir"
grep_bin="$(command -v grep)"
[[ -n "$grep_bin" ]] || fail "grep must be available to test the /proc fallback"
ln -s "$grep_bin" "$mock_fallback_dir/grep"

fallback_status=0
(
    PATH="$mock_fallback_dir"
    is_process_running "definitely_nonexistent_xyz_99999"
) || fallback_status=$?
[[ "$fallback_status" -eq 1 ]] || fail "is_process_running fallback must return 1 for a nonexistent process (got: $fallback_status)"

# --- 4. Static checks: unquoted pgrep and raw proc fallbacks outside helper ---
unquoted=$(grep -En 'pgrep -f \$' "$REPO_ROOT/src/init.sh" "$REPO_ROOT/src/core.sh" || true)
[[ -z "$unquoted" ]] || fail "src/ init.sh and core.sh must not contain unquoted pgrep -f \$ (found: $unquoted)"

# Process-detection /proc glob patterns must only appear inside is_process_running().
# /proc/*/cmdline and /proc/[0-9]* iterate over process cmdlines; other /proc uses
# (e.g. /proc/sys/kernel/random/uuid) are unrelated and allowed outside the helper.
proc_glob_violations=""
while IFS=: read -r file lineno rest; do
    [[ -z "$file" ]] && continue
    # Determine is_process_running function boundary in init.sh
    in_func=0
    if [[ "$file" == *init.sh ]]; then
        func_range=$(awk '/^is_process_running\(\) \{/{s=NR} s && /^}/{print s"-"NR; exit}' "$file")
        if [[ "$func_range" == *-* ]]; then
            func_start=${func_range%%-*}
            func_end=${func_range##*-}
            (( lineno >= func_start && lineno <= func_end )) && in_func=1
        fi
    fi
    [[ "$in_func" -eq 0 ]] && proc_glob_violations="$proc_glob_violations$file:$lineno:$rest"$'\n'
done < <(grep -En '/proc/(\*|\[0-9\])' "$REPO_ROOT/src/init.sh" "$REPO_ROOT/src/core.sh" || true)
[[ -z "$proc_glob_violations" ]] || \
    fail "src/ must encapsulate process-detection /proc globs inside is_process_running (found outside: $proc_glob_violations)"

printf '[PASS] process detection cleanup checks\n'
