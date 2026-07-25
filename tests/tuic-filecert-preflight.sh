#!/usr/bin/env bash
set -uo pipefail

# P2-02: tuic_prepare_tls_mode must reject nonexistent/unreadable cert/key for file-cert mode.

fail() {
    printf '[FAIL] %s\n' "$1" >&2
    exit 1
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/sb-filecert.XXXXXX")"
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
export TUIC_HOP_SKIP_SYSTEMD=1 TUIC_HOP_SKIP_NFT=1 TUIC_HOP_SKIP_UFW=1
mkdir -p "$is_conf_dir" "$is_backup_dir"

# shellcheck disable=SC1091
. "$REPO_ROOT/src/backup.sh"
# shellcheck disable=SC1091
. "$REPO_ROOT/src/tuic.sh"

# --- Case 1: nonexistent cert/key must be rejected ---
tuic_reset_state
tuic_insecure=
tuic_requested_tls=
tuic_cert_file_arg=1; tuic_key_file_arg=1
tuic_cert_file="$TEST_ROOT/nonexistent/fullchain.pem"
tuic_key_file="$TEST_ROOT/nonexistent/privkey.pem"
tuic_domain="example.com"
tuic_prepare_tls_mode && fail "P2-02: preflight must REJECT nonexistent cert/key" || true

# --- Case 2: valid readable cert/key must be accepted ---
tuic_reset_state
tuic_insecure=
tuic_requested_tls=
tuic_cert_file_arg=1; tuic_key_file_arg=1
tuic_cert_file="$TEST_ROOT/fullchain.pem"
tuic_key_file="$TEST_ROOT/privkey.pem"
printf 'CERT\n' >"$tuic_cert_file"
printf 'KEY\n' >"$tuic_key_file"
tuic_domain="example.com"
tuic_prepare_tls_mode || fail "P2-02: preflight must ACCEPT valid readable cert/key"
[[ $tuic_tls_mode == file-cert ]] || fail "P2-02: valid file-cert must set tuic_tls_mode=file-cert (got: $tuic_tls_mode)"

# --- Contract: source must contain the readability checks ---
grep -q '\[\[ -f $tuic_cert_file && -r $tuic_cert_file \]\]' "$REPO_ROOT/src/tuic.sh" || \
    fail "src/tuic.sh must contain -f/-r check for cert_file"
grep -q '\[\[ -f $tuic_key_file && -r $tuic_key_file \]\]' "$REPO_ROOT/src/tuic.sh" || \
    fail "src/tuic.sh must contain -f/-r check for key_file"

printf '[PASS] tuic file-cert preflight checks\n'
