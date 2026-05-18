#!/usr/bin/env bash
set -euo pipefail

fail() {
    printf '[FAIL] %s\n' "$1" >&2
    exit 1
}

assert_contains() {
    local file=$1
    local text=$2
    local description=$3
    grep -Fq -- "$text" "$file" || {
        printf '%s\n' "--- $file ---" >&2
        cat "$file" >&2
        fail "$description"
    }
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

run_sensitive_case() {
    local mode=$1
    local stdout_file=$2
    local stderr_file=$3

    MODE="$mode" REPO_ROOT="$REPO_ROOT" bash <<'EOF' >"$stdout_file" 2>"$stderr_file"
set -euo pipefail

# shellcheck disable=SC1091
. "$REPO_ROOT/src/core.sh"

msg() { printf '%b\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
ui_warn() { printf '[WARN] %s\n' "$*" >&2; }
err() { printf '[ERROR] %s\n' "$*" >&2; return 1; }

is_core_name=sing-box
is_config_name=Shadowsocks-12345.json
is_protocol=shadowsocks
net=ss
is_addr=203.0.113.10
port=12345
ss_password=secret-password
ss_method=2022-blake3-aes-128-gcm
is_new_install=
is_no_auto_tls=
is_core_stop=
is_caddy_stop=
is_new_json=
is_gen=
is_dont_auto_exit=
is_insecure=
host=

case "$MODE" in
info)
    is_dont_show_info=
    info
    ;;
url)
    url_qr url "$is_config_name"
    ;;
esac
EOF
}

INFO_OUT="$TMP_DIR/info.out"
INFO_ERR="$TMP_DIR/info.err"
run_sensitive_case info "$INFO_OUT" "$INFO_ERR"
assert_contains "$INFO_ERR" '[WARN] 下面会显示包含敏感凭据的客户端配置，请避免在共享屏幕、日志或工单中泄露。' \
    'info output must warn about sensitive credentials on stderr'
assert_contains "$INFO_OUT" 'secret-password' \
    'info output body must stay on stdout'
assert_contains "$INFO_OUT" 'ss://' \
    'info URL body must stay on stdout'

URL_OUT="$TMP_DIR/url.out"
URL_ERR="$TMP_DIR/url.err"
run_sensitive_case url "$URL_OUT" "$URL_ERR"
assert_contains "$URL_ERR" '[WARN] 下面会显示包含敏感凭据的客户端配置，请避免在共享屏幕、日志或工单中泄露。' \
    'url output must warn about sensitive credentials on stderr'
assert_contains "$URL_OUT" 'ss://' \
    'url body must stay on stdout'
assert_contains "$URL_OUT" 'Shadowsocks-12345.json & URL 链接' \
    'url heading must stay on stdout'

printf '[PASS] sensitive output warning checks\n'
