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

eval "$(sed -n '/^is_process_running()/,/^}/p' "$REPO_ROOT/src/init.sh")"

# --- 1. Test is_process_running helper function exists and handles empty/invalid ---
type is_process_running >/dev/null 2>&1 || fail "is_process_running function must exist in src/init.sh"
is_process_running "" && fail "is_process_running must return 1 for empty bin" || true
is_process_running "nonexistent_proc_xyz_99999" && fail "is_process_running must return 1 for nonexistent process" || true

# --- 2. Test is_process_running with a mocked pgrep present on PATH ---
mock_pgrep_dir="$TEST_ROOT/mock-pgrep"
mkdir -p "$mock_pgrep_dir"
# The single-quoted lines are the literal body of the mock executable.
# shellcheck disable=SC2016
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

# --- 3. Test is_process_running /proc fallback when pgrep is absent from PATH ---
mock_fallback_dir="$TEST_ROOT/mock-fallback"
mkdir -p "$mock_fallback_dir"
tr_bin="$(command -v tr)"
[[ -n "$tr_bin" ]] || fail "tr must be available to test the /proc fallback"
ln -s "$tr_bin" "$mock_fallback_dir/tr"

fake_proc_root="$TEST_ROOT/proc"
fake_proc_pid_dir="$fake_proc_root/424242"
mkdir -p "$fake_proc_pid_dir"
printf '%s\0%s\0' \
    '/usr/local/bin/sentinel_proc_running' \
    '--test-mode' > "$fake_proc_pid_dir/cmdline"

(
    PATH="$mock_fallback_dir"
    is_process_running "sentinel_proc_running" "$fake_proc_root"
) || fail "is_process_running fallback must return 0 when fake /proc contains the process"

fallback_status=0
(
    PATH="$mock_fallback_dir"
    is_process_running "definitely_nonexistent_xyz_99999" "$fake_proc_root"
) || fallback_status=$?
[[ "$fallback_status" -eq 1 ]] || fail "is_process_running fallback must return 1 for a nonexistent process (got: $fallback_status)"

# --- 4. Static checks: unquoted pgrep and raw proc fallbacks outside helper ---
unquoted=$(grep -En 'pgrep -f \$' "$REPO_ROOT/src/init.sh" "$REPO_ROOT/src/core.sh" || true)
[[ -z "$unquoted" ]] || fail "src/ init.sh and core.sh must not contain unquoted pgrep -f \$ (found: $unquoted)"

legacy_proc=$(grep -En '/proc/\*/cmdline|grep -l .*cmdline' "$REPO_ROOT/src/init.sh" "$REPO_ROOT/src/core.sh" || true)
[[ -z "$legacy_proc" ]] || \
    fail "src/ must not contain legacy raw /proc cmdline process checks (found: $legacy_proc)"

printf '[PASS] process detection cleanup checks\n'
