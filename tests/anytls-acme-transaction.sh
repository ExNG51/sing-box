#!/usr/bin/env bash
set -o pipefail

fail() {
    printf '[FAIL] %s\n' "$1" >&2
    exit 1
}

assert_match() {
    local pattern=$1
    local file=$2
    local description=$3

    if command -v rg >/dev/null 2>&1; then
        rg -n "$pattern" "$file" >/dev/null || fail "$description"
    else
        grep -En "$pattern" "$file" >/dev/null || fail "$description"
    fi
}

assert_no_match() {
    local pattern=$1
    local file=$2
    local description=$3

    if command -v rg >/dev/null 2>&1; then
        if rg -n "$pattern" "$file" >/dev/null; then
            fail "$description"
        fi
    else
        if grep -En "$pattern" "$file" >/dev/null; then
            fail "$description"
        fi
    fi
}

assert_order() {
    local first_pattern=$1
    local second_pattern=$2
    local file=$3
    local description=$4
    local first second

    first=$(awk -v pat="$first_pattern" '$0 ~ pat { print NR; exit }' "$file")
    second=$(awk -v pat="$second_pattern" '$0 ~ pat { print NR; exit }' "$file")
    [[ $first && $second && $first -lt $second ]] || fail "$description"
}

assert_json_expr() {
    local json=$1
    local expr=$2
    local description=$3

    jq -e "$expr" >/dev/null <<<"$json" || {
        printf '%s\n' "$json" >&2
        fail "$description"
    }
}

assert_log_contains() {
    local file=$1
    local text=$2
    local description=$3

    grep -Fq -- "$text" "$file" || {
        printf -- '--- %s ---\n' "$file" >&2
        cat "$file" >&2
        fail "$description"
    }
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

run_schema_generation_checks() {
    local old_json new_json normal_json reality_json

    if [[ ${BASH_VERSINFO[0]:-0} -lt 4 ]]; then
        assert_log_contains src/core.sh 'if is_core_version_ge "$is_core_ver" "1.14.0"; then' \
            'AnyTLS schema branch must compare full sing-box versions for 1.14+ ACME behavior'
        assert_log_contains src/core.sh 'is_anytls_tls="tls:{enabled:true,certificate_provider:\"$is_anytls_acme_tag\"}"' \
            'sing-box 1.14+ AnyTLS ACME must point tls.certificate_provider at a root provider tag'
        assert_log_contains src/core.sh 'is_root_extra_json=",certificate_providers:[{type:\"acme\",tag:\"$is_anytls_acme_tag\",domain:[\"$is_anytls_acme_domain\"],data_directory:\"$is_anytls_acme_data_dir\"}]"' \
            'sing-box 1.14+ AnyTLS ACME must emit root certificate_providers'
        assert_log_contains src/core.sh 'is_anytls_tls="tls:{enabled:true,acme:{domain:[\"$is_anytls_acme_domain\"],data_directory:\"$is_anytls_acme_data_dir\"}}"' \
            'sing-box 1.13.x AnyTLS ACME must keep tls.acme with data_directory'
        assert_log_contains src/core.sh 'is_add_public_key=' \
            'create server must reset reality and root-level JSON helpers before regenerating config'
        return 0
    fi

    old_json="$(
        TEST_ROOT="$TEST_ROOT" REPO_ROOT="$REPO_ROOT" bash <<'EOF'
set -o pipefail
. "$REPO_ROOT/src/core.sh"

msg() { :; }
warn() { :; }
err() {
    printf 'ERROR: %s\n' "$*" >&2
    return 1
}
_green() { :; }
_yellow() { :; }
_cyan() { :; }
_red() { :; }
_red_bg() { printf '%s' "$*"; }
get_ip() { ip=203.0.113.10; }
get_port() { tmp_port=443; }
get_uuid() { tmp_uuid='11111111-1111-1111-1111-111111111111'; }
get_pbk() {
    is_public_key=public-key
    is_private_key=private-key
}

is_conf_dir="$TEST_ROOT/conf"
is_core_dir=/etc/sing-box
is_tls_key=/etc/sing-box/bin/tls.key
is_tls_cer=/etc/sing-box/bin/tls.cer
mkdir -p "$is_conf_dir"

is_test_json=1
is_core_ver=1.13.9
host=
port=443
uuid='11111111-1111-1111-1111-111111111111'
password=secret
is_anytls_domain=example.com

create server AnyTLS
printf '%s\n' "$is_new_json"
EOF
    )"
    assert_json_expr "$old_json" '.inbounds[0].type == "anytls"' \
        'AnyTLS config must keep the anytls inbound type'
    assert_json_expr "$old_json" '.inbounds[0].tls.acme.domain[0] == "example.com"' \
        'sing-box 1.13.x AnyTLS ACME must use tls.acme'
    assert_json_expr "$old_json" 'has("certificate_providers") | not' \
        'sing-box 1.13.x AnyTLS ACME must not emit root certificate_providers'

    new_json="$(
        TEST_ROOT="$TEST_ROOT" REPO_ROOT="$REPO_ROOT" bash <<'EOF'
set -o pipefail
. "$REPO_ROOT/src/core.sh"

msg() { :; }
warn() { :; }
err() {
    printf 'ERROR: %s\n' "$*" >&2
    return 1
}
_green() { :; }
_yellow() { :; }
_cyan() { :; }
_red() { :; }
_red_bg() { printf '%s' "$*"; }
get_ip() { ip=203.0.113.10; }
get_port() { tmp_port=443; }
get_uuid() { tmp_uuid='11111111-1111-1111-1111-111111111111'; }
get_pbk() {
    is_public_key=public-key
    is_private_key=private-key
}

is_conf_dir="$TEST_ROOT/conf"
is_core_dir=/etc/sing-box
is_tls_key=/etc/sing-box/bin/tls.key
is_tls_cer=/etc/sing-box/bin/tls.cer
mkdir -p "$is_conf_dir"

is_test_json=1
is_core_ver=1.14.0
host=
port=443
uuid='11111111-1111-1111-1111-111111111111'
password=secret
is_anytls_domain=example.com

create server AnyTLS
printf '%s\n' "$is_new_json"
EOF
    )"
    assert_json_expr "$new_json" '.inbounds[0].tls.certificate_provider == "acme-example.com"' \
        'sing-box 1.14.x AnyTLS ACME must reference a top-level certificate provider tag'
    assert_json_expr "$new_json" '.certificate_providers[0].type == "acme"' \
        'sing-box 1.14.x AnyTLS ACME must emit a top-level acme provider'
    assert_json_expr "$new_json" '.certificate_providers[0].domain[0] == "example.com"' \
        'sing-box 1.14.x AnyTLS ACME provider must carry the domain'
    assert_json_expr "$new_json" '.certificate_providers[0].data_directory == "/etc/sing-box/acme"' \
        'sing-box 1.14.x AnyTLS ACME provider must define data_directory'

    normal_json="$(
        TEST_ROOT="$TEST_ROOT" REPO_ROOT="$REPO_ROOT" bash <<'EOF'
set -o pipefail
. "$REPO_ROOT/src/core.sh"

msg() { :; }
warn() { :; }
err() {
    printf 'ERROR: %s\n' "$*" >&2
    return 1
}
_green() { :; }
_yellow() { :; }
_cyan() { :; }
_red() { :; }
_red_bg() { printf '%s' "$*"; }
get_ip() { ip=203.0.113.10; }
get_port() { tmp_port=8443; }
get_uuid() { tmp_uuid='11111111-1111-1111-1111-111111111111'; }
get_pbk() {
    is_public_key=public-key
    is_private_key=private-key
}

is_conf_dir="$TEST_ROOT/conf"
is_core_dir=/etc/sing-box
is_tls_key=/etc/sing-box/bin/tls.key
is_tls_cer=/etc/sing-box/bin/tls.cer
mkdir -p "$is_conf_dir"

is_test_json=1
is_core_ver=1.14.0
host=
port=8443
uuid='11111111-1111-1111-1111-111111111111'
password=secret
unset is_anytls_domain

create server AnyTLS
printf '%s\n' "$is_new_json"
EOF
    )"
    assert_json_expr "$normal_json" '.inbounds[0].tls.key_path == "/etc/sing-box/bin/tls.key"' \
        'AnyTLS without domain must keep local TLS key_path'
    assert_json_expr "$normal_json" 'has("certificate_providers") | not' \
        'AnyTLS without domain must not emit certificate_providers'

    reality_json="$(
        TEST_ROOT="$TEST_ROOT" REPO_ROOT="$REPO_ROOT" bash <<'EOF'
set -o pipefail
. "$REPO_ROOT/src/core.sh"

msg() { :; }
warn() { :; }
err() {
    printf 'ERROR: %s\n' "$*" >&2
    return 1
}
_green() { :; }
_yellow() { :; }
_cyan() { :; }
_red() { :; }
_red_bg() { printf '%s' "$*"; }
get_ip() { ip=203.0.113.10; }
get_port() { tmp_port=443; }
get_uuid() { tmp_uuid='11111111-1111-1111-1111-111111111111'; }
get_pbk() {
    is_public_key=generated-public
    is_private_key=generated-private
}

is_conf_dir="$TEST_ROOT/conf"
is_core_dir=/etc/sing-box
is_tls_key=/etc/sing-box/bin/tls.key
is_tls_cer=/etc/sing-box/bin/tls.cer
mkdir -p "$is_conf_dir"

is_test_json=1
is_core_ver=1.14.0
host=
port=443
uuid='11111111-1111-1111-1111-111111111111'
password=secret
is_anytls_domain=example.com
create server AnyTLS >/dev/null

json_str=
port=8443
uuid='22222222-2222-2222-2222-222222222222'
is_private_key=explicit-private
is_public_key=explicit-public
is_servername=www.cloudflare.com
unset is_anytls_domain password
host=

create server VLESS-REALITY
printf '%s\n' "$is_new_json"
EOF
    )"
    assert_json_expr "$reality_json" 'has("certificate_providers") | not' \
        'Reality config must not be polluted by a previous AnyTLS ACME root object'
}

run_firewall_checks() {
    local fakebin log

    fakebin="$TEST_ROOT/firewall-bin"
    log="$TEST_ROOT/firewall.log"
    mkdir -p "$fakebin"
    : >"$log"

    cat >"$fakebin/ufw" <<'EOF'
#!/usr/bin/env bash
set -o pipefail
case ${1-} in
status)
    printf 'Status: active\n'
    ;;
allow)
    printf 'ufw %s\n' "$*" >>"$TEST_FIREWALL_LOG"
    ;;
esac
EOF
    chmod +x "$fakebin/ufw"

    TEST_FIREWALL_LOG="$log" PATH="$fakebin:/usr/bin:/bin" REPO_ROOT="$REPO_ROOT" bash <<'EOF'
set -o pipefail
msg() { printf 'MSG:%s\n' "$*" >>"$TEST_FIREWALL_LOG"; }
warn() { printf 'WARN:%s\n' "$*" >>"$TEST_FIREWALL_LOG"; }
err() {
    printf 'ERR:%s\n' "$*" >>"$TEST_FIREWALL_LOG"
    return 1
}
_green() { printf 'GREEN:%s\n' "$*" >>"$TEST_FIREWALL_LOG"; }
ask() { printf 'ASK:%s|%s|%s\n' "$1" "$2" "$3" >>"$TEST_FIREWALL_LOG"; }
. "$REPO_ROOT/src/firewall.sh"
ensure_anytls_acme_firewall_443
EOF
    assert_log_contains "$log" 'ufw allow 443/tcp' \
        'UFW backend must open TCP 443 automatically'

    rm -f "$fakebin/ufw"
    cat >"$fakebin/firewall-cmd" <<'EOF'
#!/usr/bin/env bash
set -o pipefail
case "$*" in
--state)
    exit 0
    ;;
--query-port=443/tcp)
    exit 1
    ;;
--permanent\ --add-port=443/tcp)
    printf 'firewall-cmd %s\n' "$*" >>"$TEST_FIREWALL_LOG"
    exit 0
    ;;
--reload)
    printf 'firewall-cmd %s\n' "$*" >>"$TEST_FIREWALL_LOG"
    exit 0
    ;;
esac
exit 0
EOF
    chmod +x "$fakebin/firewall-cmd"
    : >"$log"

    TEST_FIREWALL_LOG="$log" PATH="$fakebin:/usr/bin:/bin" REPO_ROOT="$REPO_ROOT" bash <<'EOF'
set -o pipefail
msg() { printf 'MSG:%s\n' "$*" >>"$TEST_FIREWALL_LOG"; }
warn() { printf 'WARN:%s\n' "$*" >>"$TEST_FIREWALL_LOG"; }
err() {
    printf 'ERR:%s\n' "$*" >>"$TEST_FIREWALL_LOG"
    return 1
}
_green() { printf 'GREEN:%s\n' "$*" >>"$TEST_FIREWALL_LOG"; }
ask() { printf 'ASK:%s|%s|%s\n' "$1" "$2" "$3" >>"$TEST_FIREWALL_LOG"; }
. "$REPO_ROOT/src/firewall.sh"
ensure_anytls_acme_firewall_443
EOF
    assert_log_contains "$log" 'firewall-cmd --permanent --add-port=443/tcp' \
        'firewalld backend must add a permanent TCP 443 rule'
    assert_log_contains "$log" 'firewall-cmd --reload' \
        'firewalld backend must reload after adding TCP 443'

    rm -f "$fakebin/firewall-cmd"
    cat >"$fakebin/nft" <<'EOF'
#!/usr/bin/env bash
set -o pipefail
case ${1-} in
list)
    exit 0
    ;;
esac
exit 0
EOF
    chmod +x "$fakebin/nft"
    : >"$log"

    TEST_FIREWALL_LOG="$log" PATH="$fakebin:/usr/bin:/bin" REPO_ROOT="$REPO_ROOT" bash <<'EOF'
set -o pipefail
msg() { printf 'MSG:%s\n' "$*" >>"$TEST_FIREWALL_LOG"; }
warn() { printf 'WARN:%s\n' "$*" >>"$TEST_FIREWALL_LOG"; }
err() {
    printf 'ERR:%s\n' "$*" >>"$TEST_FIREWALL_LOG"
    return 1
}
_green() { printf 'GREEN:%s\n' "$*" >>"$TEST_FIREWALL_LOG"; }
ask() { printf 'ASK:%s|%s|%s\n' "$1" "$2" "$3" >>"$TEST_FIREWALL_LOG"; }
. "$REPO_ROOT/src/firewall.sh"
is_main_start=1
ensure_anytls_acme_firewall_443
EOF
    assert_log_contains "$log" '参考检查命令：nft list ruleset' \
        'nftables backend must warn instead of modifying rules directly'
    assert_log_contains "$log" 'ASK:string|y|我已确认 TCP 443 入站已放行 [y]:' \
        'interactive nftables path must require manual confirmation'

    rm -f "$fakebin/nft"
    cat >"$fakebin/iptables" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
-S\ INPUT)
    exit 0
    ;;
esac
exit 0
EOF
    chmod +x "$fakebin/iptables"
    : >"$log"

    TEST_FIREWALL_LOG="$log" PATH="$fakebin:/usr/bin:/bin" REPO_ROOT="$REPO_ROOT" bash <<'EOF'
set -o pipefail
msg() { printf 'MSG:%s\n' "$*" >>"$TEST_FIREWALL_LOG"; }
warn() { printf 'WARN:%s\n' "$*" >>"$TEST_FIREWALL_LOG"; }
err() {
    printf 'ERR:%s\n' "$*" >>"$TEST_FIREWALL_LOG"
    return 1
}
_green() { printf 'GREEN:%s\n' "$*" >>"$TEST_FIREWALL_LOG"; }
ask() { printf 'ASK:%s|%s|%s\n' "$1" "$2" "$3" >>"$TEST_FIREWALL_LOG"; }
. "$REPO_ROOT/src/firewall.sh"
is_main_start=1
ensure_anytls_acme_firewall_443
EOF
    assert_log_contains "$log" 'iptables -C INPUT -p tcp --dport 443 -j ACCEPT' \
        'iptables backend must warn with a manual allow reference instead of editing rules directly'
    assert_log_contains "$log" 'ASK:string|y|我已确认 TCP 443 入站已放行 [y]:' \
        'interactive iptables path must require manual confirmation'

    rm -f "$fakebin/iptables"
    : >"$log"
    TEST_FIREWALL_LOG="$log" PATH="/usr/bin:/bin" REPO_ROOT="$REPO_ROOT" bash <<'EOF'
set -o pipefail
msg() { printf 'MSG:%s\n' "$*" >>"$TEST_FIREWALL_LOG"; }
warn() { printf 'WARN:%s\n' "$*" >>"$TEST_FIREWALL_LOG"; }
err() {
    printf 'ERR:%s\n' "$*" >>"$TEST_FIREWALL_LOG"
    return 1
}
_green() { printf 'GREEN:%s\n' "$*" >>"$TEST_FIREWALL_LOG"; }
ask() { printf 'ASK:%s|%s|%s\n' "$1" "$2" "$3" >>"$TEST_FIREWALL_LOG"; }
. "$REPO_ROOT/src/firewall.sh"
ensure_anytls_acme_firewall_443
warn_anytls_acme_external_firewall
EOF
    assert_log_contains "$log" 'MSG:' \
        'none backend must still emit user-facing guidance'
    assert_log_contains "$log" '云安全组已放行 TCP 443' \
        'cloud firewall reminder must be shown'
}

run_transaction_checks() {
    local log
    log="$TEST_ROOT/transaction.log"
    : >"$log"

    TEST_TX_LOG="$log" REPO_ROOT="$REPO_ROOT" bash <<'EOF'
set -o pipefail
. "$REPO_ROOT/src/core.sh"

msg() { printf 'MSG:%s\n' "$*" >>"$TEST_TX_LOG"; }
warn() { printf 'WARN:%s\n' "$*" >>"$TEST_TX_LOG"; }
err() {
    printf 'ERR:%s\n' "$*" >>"$TEST_TX_LOG"
    return 1
}
begin_backup_transaction_if_needed() {
    printf 'begin\n' >>"$TEST_TX_LOG"
    IS_BACKUP_ACTIVE=true
    return 0
}
finalize_backup_transaction() {
    printf 'finalize\n' >>"$TEST_TX_LOG"
    IS_BACKUP_ACTIVE=false
    return 0
}
ensure_server_config_json_exists() {
    printf 'base-config\n' >>"$TEST_TX_LOG"
    return 0
}
check_pending_server_config() {
    printf 'check\n' >>"$TEST_TX_LOG"
    return 0
}
safe_ensure_dir() {
    printf 'mkdir:%s\n' "$1" >>"$TEST_TX_LOG"
    return 0
}
safe_write_file() {
    printf 'write:%s\n' "$1" >>"$TEST_TX_LOG"
    return 0
}
restart_core_and_verify() {
    printf 'restart\n' >>"$TEST_TX_LOG"
    return 1
}
rollback_latest_backup() {
    printf 'rollback:%s\n' "$*" >>"$TEST_TX_LOG"
    return 0
}

is_anytls_acme_data_dir=/etc/sing-box/acme
is_json_file=/etc/sing-box/conf/AnyTLS-example.com.json
is_new_json='{"inbounds":[]}'

commit_server_config_with_validation && exit 1
EOF
    assert_log_contains "$log" 'begin' \
        'AnyTLS ACME commit path must begin a backup transaction'
    assert_log_contains "$log" 'base-config' \
        'AnyTLS ACME commit path must ensure config.json exists before check'
    assert_order '^check$' '^write:/etc/sing-box/conf/AnyTLS-example.com.json$' "$log" \
        'AnyTLS ACME commit path must check candidate config before writing production config'
    assert_log_contains "$log" 'restart' \
        'AnyTLS ACME commit path must verify restart synchronously'
    assert_order '^finalize$' '^rollback:--yes$' "$log" \
        'AnyTLS ACME rollback must finalize the current transaction before rollback_latest_backup'
    assert_log_contains "$log" 'ERR:AnyTLS ACME 添加失败，已尝试回滚。' \
        'AnyTLS ACME restart failure must terminate with an explicit rollback error'

    : >"$log"
    TEST_TX_LOG="$log" REPO_ROOT="$REPO_ROOT" bash <<'EOF'
set -o pipefail
. "$REPO_ROOT/src/core.sh"

msg() { printf 'MSG:%s\n' "$*" >>"$TEST_TX_LOG"; }
warn() { printf 'WARN:%s\n' "$*" >>"$TEST_TX_LOG"; }
safe_remove_path() {
    printf 'remove:%s\n' "$1" >>"$TEST_TX_LOG"
    return 0
}
manage() {
    printf 'manage:%s %s\n' "${1-}" "${2-}" >>"$TEST_TX_LOG"
    return 0
}

unset -f rollback_latest_backup 2>/dev/null || true
is_json_file=/etc/sing-box/conf/AnyTLS-example.com.json
rollback_or_remove_failed_anytls_config
EOF
    assert_log_contains "$log" 'remove:/etc/sing-box/conf/AnyTLS-example.com.json' \
        'fallback rollback path must only delete the new AnyTLS config file'
    assert_log_contains "$log" 'manage:restart ' \
        'fallback rollback path must restart sing-box after removing the bad config'
}

run_acme_capability_check() {
    local fake_core
    fake_core="$TEST_ROOT/fake-sing-box"

    cat >"$fake_core" <<'EOF'
#!/usr/bin/env bash
set -o pipefail
cat <<'OUT'
sing-box version 1.14.0
tags: with_acme with_quic
OUT
EOF
    chmod +x "$fake_core"

    REPO_ROOT="$REPO_ROOT" FAKE_CORE="$fake_core" bash <<'EOF'
set -o pipefail
. "$REPO_ROOT/src/core.sh"
warn() { :; }
err() {
    printf 'ERROR: %s\n' "$*" >&2
    return 1
}
is_core_bin="$FAKE_CORE"
assert_core_acme_capability
EOF

    cat >"$fake_core" <<'EOF'
#!/usr/bin/env bash
set -o pipefail
cat <<'OUT'
sing-box version 1.14.0
tags: with_quic with_gvisor
OUT
EOF
    chmod +x "$fake_core"

    if REPO_ROOT="$REPO_ROOT" FAKE_CORE="$fake_core" bash <<'EOF'
set -euo pipefail
. "$REPO_ROOT/src/core.sh"
warn() { :; }
err() {
    printf 'ERROR: %s\n' "$*" >&2
    return 1
}
is_core_bin="$FAKE_CORE"
assert_core_acme_capability
EOF
    then
        fail 'assert_core_acme_capability must fail when tags omit with_acme'
    fi
}

shopt -s nullglob
for file in install.sh sing-box.sh src/*.sh tests/*.sh tests/audit/*.sh; do
    [[ -f $file ]] || continue
    bash -n "$file"
done

assert_match 'AnyTLS 是否使用域名并启用 sing-box ACME 自动证书' src/core.sh \
    'AnyTLS menu prompt must describe ACME automatic certificates instead of pre-applying a certificate'
assert_match '脚本将写入 sing-box ACME 自动证书配置' src/core.sh \
    'AnyTLS menu prompt must explain that the script only writes ACME config'
assert_no_match 'AnyTLS 是否申请证书并使用域名连接' src/core.sh \
    'legacy AnyTLS prompt that implies the script applies the certificate must be removed'
assert_match 'preflight_anytls_acme' src/core.sh \
    'AnyTLS ACME flow must call a dedicated preflight function'
assert_match 'commit_server_config_with_validation' src/core.sh \
    'AnyTLS ACME flow must use the validated commit path'
assert_match 'load firewall\.sh' src/core.sh \
    'AnyTLS ACME preflight must load the dedicated firewall module'
assert_match 'run: bash tests/anytls-acme-transaction\.sh' .github/workflows/release.yml \
    'release workflow must run AnyTLS ACME transaction checks before packaging'
assert_order 'run: bash tests/anytls-acme-transaction\.sh' '- name: tar' .github/workflows/release.yml \
    'release workflow AnyTLS ACME transaction checks must run before tar packaging'

run_schema_generation_checks
run_firewall_checks
run_transaction_checks
run_acme_capability_check

printf '[PASS] AnyTLS ACME transaction checks\n'
