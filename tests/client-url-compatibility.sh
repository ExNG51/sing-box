#!/usr/bin/env bash
set -uo pipefail

# Optimization Area 2: Client URL parameter compatibility & Hysteria2 cert fingerprint checks.

fail() {
    printf '[FAIL] %s\n' "$1" >&2
    exit 1
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/sb-url-compat.XXXXXX")"
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

mkdir -p "$is_conf_dir" "$is_backup_dir"

# --- 1. Static checks for dual insecure parameters in src/core.sh and src/tuic.sh ---
grep -q 'type=tcp&security=tls&insecure=1&allowInsecure=1' "$REPO_ROOT/src/core.sh" || \
    fail "src/core.sh Trojan URL must render insecure=1&allowInsecure=1"

grep -q 'insecure=1&allow_insecure=1&congestion_control=bbr' "$REPO_ROOT/src/core.sh" || \
    fail "src/core.sh TUIC legacy URL must render insecure=1&allow_insecure=1"

grep -q 'anytls://.*insecure=1&allowInsecure=1' "$REPO_ROOT/src/core.sh" || \
    fail "src/core.sh AnyTLS legacy URL must render insecure=1&allowInsecure=1"

grep -q 'insecure=1&allow_insecure=1' "$REPO_ROOT/src/tuic.sh" || \
    fail "src/tuic.sh structured TUIC URL must render insecure=1&allow_insecure=1"

grep -q 'pinSHA256' "$REPO_ROOT/src/core.sh" || \
    fail "src/core.sh Hysteria2 URL must support pinSHA256 fingerprint"

# --- 2. Dynamic test for structured TUIC URL rendering ---
# shellcheck disable=SC1091
. "$REPO_ROOT/src/backup.sh"
# shellcheck disable=SC1091
. "$REPO_ROOT/src/tuic.sh"

tuic_reset_state
tuic_insecure=1
tuic_requested_tls=
tuic_cert_file_arg=
tuic_key_file_arg=
tuic_cert_file=""
tuic_key_file=""
tuic_domain=
tuic_port=10443
tuic_uuid="11111111-1111-1111-1111-111111111111"
tuic_password="pass"
tuic_cc="bbr"
tuic_tls_mode="self-signed-insecure"

tuic_json=$(tuic_render_inbound_json)
rendered_url=$(tuic_render_client_url "$tuic_json")

[[ $rendered_url == *"insecure=1"* ]] || fail "structured TUIC URL must contain insecure=1"
[[ $rendered_url == *"allow_insecure=1"* ]] || fail "structured TUIC URL must contain allow_insecure=1"

# --- 3. Dynamic checks for legacy URL rendering in src/core.sh ---
# Evaluate the real case-arm bodies with the minimum state each URL template reads.
extract_info_case_arm() {
    sed -n '/^info() {/,/^}/p' "$REPO_ROOT/src/core.sh" |
        sed -n "/^    $1)/,/^        ;;/p" | sed '1d;$d'
}

trojan_arm="$(extract_info_case_arm trojan)"
hysteria_arm="$(extract_info_case_arm 'hy[*]')"
tuic_arm="$(extract_info_case_arm tuic)"
anytls_arm="$(extract_info_case_arm anytls)"

[[ -n $trojan_arm ]] || fail "could not extract Trojan URL case arm"
[[ -n $hysteria_arm ]] || fail "could not extract Hysteria2 URL case arm"
[[ -n $tuic_arm ]] || fail "could not extract legacy TUIC URL case arm"
[[ -n $anytls_arm ]] || fail "could not extract AnyTLS URL case arm"

is_protocol=trojan
is_addr=10.0.0.1
port=443
password=testpass
is_core_name=sing-box
net=tcp
is_url=
is_can_change=()
is_info_show=()
is_info_str=()
eval "$trojan_arm"
[[ $is_url == *"insecure=1&allowInsecure=1"* ]] || \
    fail "Trojan URL must contain dual insecure parameters, got: $is_url"

is_protocol=tuic
is_addr=10.0.0.1
port=10443
uuid=11111111-1111-1111-1111-111111111111
password=testpass
is_core_name=sing-box
net=udp
is_url=
is_can_change=()
is_info_show=()
is_info_str=()
eval "$tuic_arm"
[[ $is_url == *"alpn=h3&insecure=1&allow_insecure=1&congestion_control=bbr"* ]] || \
    fail "legacy TUIC URL must contain dual insecure parameters, got: $is_url"

: > "$TEST_ROOT/tls.cer"
mock_openssl_dir="$TEST_ROOT/mock-openssl"
mock_openssl_args="$TEST_ROOT/openssl.args"
mkdir -p "$mock_openssl_dir"
# The single-quoted lines are the literal body of the mock executable.
# shellcheck disable=SC2016
printf '%s\n' \
    '#!/bin/sh' \
    'printf "%s\n" "$*" > "$OPENSSL_ARGS_FILE"' \
    'printf "sha256 Fingerprint=AA:BB\n"' > "$mock_openssl_dir/openssl"
chmod +x "$mock_openssl_dir/openssl"
export OPENSSL_ARGS_FILE="$mock_openssl_args"

hysteria_url_with_openssl=$(PATH="$mock_openssl_dir:$PATH"; export PATH
    is_protocol=hysteria2
    is_addr=10.0.0.1
    port=443
    password=testpass
    is_core_name=sing-box
    net=udp
    is_tls_cer="$TEST_ROOT/tls.cer"
    is_url=
    is_can_change=()
    is_info_show=()
    is_info_str=()
    eval "$hysteria_arm"
    printf '%s' "$is_url")
[[ $hysteria_url_with_openssl == *"insecure=1&allowInsecure=1"* ]] || \
    fail "Hysteria2 URL with openssl must contain dual insecure parameters, got: $hysteria_url_with_openssl"
[[ $hysteria_url_with_openssl == *"pinSHA256=AABB"* ]] || \
    fail "Hysteria2 URL with openssl must contain pinSHA256, got: $hysteria_url_with_openssl"
expected_openssl_args="x509 -noout -fingerprint -sha256 -in $TEST_ROOT/tls.cer"
[[ -f $mock_openssl_args && $(cat "$mock_openssl_args") == "$expected_openssl_args" ]] || \
    fail "Hysteria2 fingerprint must call openssl with the expected arguments"

# PATH is intentionally replaced inside this command substitution.
# shellcheck disable=SC2123
hysteria_url_without_openssl=$(PATH="$TEST_ROOT/no-openssl"; export PATH
    is_protocol=hysteria2
    is_addr=10.0.0.1
    port=443
    password=testpass
    is_core_name=sing-box
    net=udp
    is_tls_cer="$TEST_ROOT/tls.cer"
    is_url=
    is_can_change=()
    is_info_show=()
    is_info_str=()
    eval "$hysteria_arm"
    printf '%s' "$is_url")
[[ $hysteria_url_without_openssl == *"insecure=1&allowInsecure=1"* ]] || \
    fail "Hysteria2 URL without openssl must contain dual insecure parameters, got: $hysteria_url_without_openssl"
[[ $hysteria_url_without_openssl != *"pinSHA256="* ]] || \
    fail "Hysteria2 URL without openssl must not contain pinSHA256, got: $hysteria_url_without_openssl"

function_only_bin="$TEST_ROOT/function-only-bin"
mkdir -p "$function_only_bin"
ln -s "$(command -v sed)" "$function_only_bin/sed"
# PATH modification is intentionally local to this command substitution.
# shellcheck disable=SC2030
hysteria_url_with_function_only=$(PATH="$function_only_bin"; export PATH
    # Invoked indirectly by the eval-extracted Hysteria2 case arm.
    # shellcheck disable=SC2329
    openssl() { printf 'sha256 Fingerprint=CC:DD\n'; }
    is_protocol=hysteria2
    is_addr=10.0.0.1
    port=443
    password=testpass
    is_core_name=sing-box
    net=udp
    is_tls_cer="$TEST_ROOT/tls.cer"
    is_url=
    is_can_change=()
    is_info_show=()
    is_info_str=()
    eval "$hysteria_arm"
    printf '%s' "$is_url")
[[ $hysteria_url_with_function_only != *"pinSHA256="* ]] || \
    fail "Hysteria2 URL must ignore a function-only openssl preflight, got: $hysteria_url_with_function_only"

rm -f "$mock_openssl_args"
# Variables inside the command substitution are consumed by the eval-extracted arm.
# PATH intentionally returns to the parent value for this isolated render.
# shellcheck disable=SC2031,SC2034
hysteria_url_without_cert=$(PATH="$mock_openssl_dir:$PATH"; export PATH
    is_protocol=hysteria2
    is_addr=10.0.0.1
    port=443
    password=testpass
    is_core_name=sing-box
    net=udp
    is_tls_cer="$TEST_ROOT/missing.cer"
    is_url=
    is_can_change=()
    is_info_show=()
    is_info_str=()
    eval "$hysteria_arm"
    printf '%s' "$is_url")
[[ $hysteria_url_without_cert != *"pinSHA256="* ]] || \
    fail "Hysteria2 URL without a readable certificate must not contain pinSHA256"
[[ ! -e $mock_openssl_args ]] || fail "openssl must not run when the certificate is missing"

# Variables in this state block are consumed by the eval-extracted AnyTLS arm.
# shellcheck disable=SC2034
{
    is_protocol=anytls
    is_addr=10.0.0.1
    port=443
    password=testpass
    is_core_name=sing-box
    net=tcp
    is_anytls_domain=
    is_url=
    is_can_change=()
    is_info_show=()
    is_info_str=()
    eval "$anytls_arm"
}
[[ $is_url == *"insecure=1&allowInsecure=1"* ]] || \
    fail "AnyTLS insecure URL must contain dual insecure parameters, got: $is_url"

printf '[PASS] client URL compatibility checks\n'
