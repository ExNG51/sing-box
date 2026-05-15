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

assert_log_not_contains() {
    local file=$1
    local text=$2
    local description=$3

    if grep -Fq -- "$text" "$file"; then
        printf -- '--- %s ---\n' "$file" >&2
        cat "$file" >&2
        fail "$description"
    fi
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
    run_firewalld_case() {
        local runtime_allowed=$1
        local permanent_allowed=$2

        cat >"$fakebin/firewall-cmd" <<EOF
#!/usr/bin/env bash
set -o pipefail
printf 'firewall-cmd %s\n' "\$*" >>"\$TEST_FIREWALL_LOG"
case "\$*" in
--state)
    exit 0
    ;;
--query-port=443/tcp)
    [[ $runtime_allowed == true ]] && exit 0 || exit 1
    ;;
--permanent\ --query-port=443/tcp)
    [[ $permanent_allowed == true ]] && exit 0 || exit 1
    ;;
--permanent\ --add-port=443/tcp)
    exit 0
    ;;
--reload)
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
        assert_no_match 'firewall-cmd .*(reset|flush|default)' "$log" \
            'firewalld automation must not reset, flush, or change default policy'
    }

    run_firewalld_case true true
    assert_log_contains "$log" 'firewall-cmd --query-port=443/tcp' \
        'firewalld runtime query must be performed'
    assert_log_contains "$log" 'firewall-cmd --permanent --query-port=443/tcp' \
        'firewalld permanent query must be performed'
    assert_log_not_contains "$log" 'firewall-cmd --permanent --add-port=443/tcp' \
        'firewalld must not rewrite an existing permanent TCP 443 rule'
    assert_log_not_contains "$log" 'firewall-cmd --reload' \
        'firewalld must not reload when runtime and permanent TCP 443 are already allowed'

    run_firewalld_case true false
    assert_log_contains "$log" 'firewall-cmd --permanent --add-port=443/tcp' \
        'firewalld must backfill a missing permanent TCP 443 rule when runtime already allows it'
    assert_log_contains "$log" 'firewall-cmd --reload' \
        'firewalld must reload after backfilling permanent TCP 443'

    run_firewalld_case false true
    assert_log_not_contains "$log" 'firewall-cmd --permanent --add-port=443/tcp' \
        'firewalld must not duplicate an existing permanent TCP 443 rule'
    assert_log_contains "$log" 'firewall-cmd --reload' \
        'firewalld must reload to realize a permanent-only TCP 443 rule in runtime'

    run_firewalld_case false false
    assert_log_contains "$log" 'firewall-cmd --permanent --add-port=443/tcp' \
        'firewalld must add a permanent TCP 443 rule when both runtime and permanent are absent'
    assert_log_contains "$log" 'firewall-cmd --reload' \
        'firewalld must reload after adding a new permanent TCP 443 rule'

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
check_pending_server_config() {
    printf 'check\n' >>"$TEST_TX_LOG"
    return 1
}
write_server_config_json_if_missing() {
    printf 'write-config-helper\n' >>"$TEST_TX_LOG"
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
    return 0
}
rollback_latest_backup() {
    printf 'rollback:%s\n' "$*" >>"$TEST_TX_LOG"
    return 0
}
print_anytls_acme_failure_guidance() {
    printf 'guidance\n' >>"$TEST_TX_LOG"
}

IS_BACKUP_ACTIVE=false
is_config_json=/etc/sing-box/config.json
is_anytls_acme_data_dir=/etc/sing-box/acme
is_json_file=/etc/sing-box/conf/AnyTLS-example.com.json
is_new_json='{"inbounds":[]}'

commit_server_config_with_validation && exit 1
printf 'active:%s\n' "$IS_BACKUP_ACTIVE" >>"$TEST_TX_LOG"
EOF
    assert_log_contains "$log" 'check' \
        'AnyTLS ACME check failure path must still validate the candidate configuration'
    assert_log_not_contains "$log" 'begin' \
        'AnyTLS ACME check failure must not open a production backup transaction before validation passes'
    assert_log_not_contains "$log" 'write:/etc/sing-box/config.json' \
        'AnyTLS ACME check failure must not write config.json before validation succeeds'
    assert_log_not_contains "$log" 'write:/etc/sing-box/conf/AnyTLS-example.com.json' \
        'AnyTLS ACME check failure must not write the AnyTLS inbound file before validation succeeds'
    assert_log_not_contains "$log" 'rollback:--yes' \
        'AnyTLS ACME check failure must not rollback when nothing was written to production'
    assert_log_contains "$log" 'guidance' \
        'AnyTLS ACME check failure must print follow-up guidance'
    assert_log_contains "$log" 'ERR:sing-box 配置检查失败，未写入生产配置。' \
        'AnyTLS ACME check failure must terminate with an explicit validation error'
    assert_log_contains "$log" 'active:false' \
        'AnyTLS ACME check failure must not leave an active backup transaction behind'

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
check_pending_server_config() {
    printf 'check\n' >>"$TEST_TX_LOG"
    return 0
}
render_server_config_json() {
    printf '%s\n' '{"log":{}}'
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
    return 0
}
rollback_latest_backup() {
    printf 'rollback:%s\n' "$*" >>"$TEST_TX_LOG"
    return 0
}

is_config_json=/etc/sing-box/config.json
is_anytls_acme_data_dir=/etc/sing-box/acme
is_json_file=/etc/sing-box/conf/AnyTLS-example.com.json
is_new_json='{"inbounds":[]}'

commit_server_config_with_validation
EOF
    assert_order '^check$' '^begin$' "$log" \
        'AnyTLS ACME commit must validate the candidate config before opening the production transaction'
    assert_order '^begin$' '^write:/etc/sing-box/config.json$' "$log" \
        'AnyTLS ACME commit must write config.json only after the transaction begins'
    assert_order '^write:/etc/sing-box/config.json$' '^write:/etc/sing-box/conf/AnyTLS-example.com.json$' "$log" \
        'AnyTLS ACME commit must create config.json before writing the AnyTLS inbound file when config.json is missing'
    assert_order '^write:/etc/sing-box/conf/AnyTLS-example.com.json$' '^restart$' "$log" \
        'AnyTLS ACME commit must restart sing-box after production files are written'
    assert_order '^restart$' '^finalize$' "$log" \
        'AnyTLS ACME success path must finalize the backup transaction after restart verification'

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
check_pending_server_config() {
    printf 'check\n' >>"$TEST_TX_LOG"
    return 0
}
render_server_config_json() {
    printf '%s\n' '{"log":{}}'
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

is_config_json=/etc/sing-box/config.json
is_anytls_acme_data_dir=/etc/sing-box/acme
is_json_file=/etc/sing-box/conf/AnyTLS-example.com.json
is_new_json='{"inbounds":[]}'

commit_server_config_with_validation && exit 1
EOF
    assert_order '^check$' '^begin$' "$log" \
        'AnyTLS ACME restart failure path must validate the candidate config before opening a backup transaction'
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

run_systemd_sandbox_checks() {
    local log
    log="$TEST_ROOT/systemd-sandbox.log"

    assert_match 'ensure_anytls_acme_systemd_writable_paths' src/core.sh \
        'AnyTLS ACME flow must define a dedicated systemd sandbox writable path helper'
    assert_match 'ReadWritePaths=' src/core.sh \
        'AnyTLS ACME systemd override must render ReadWritePaths content'
    assert_match '10-anytls-acme\.conf' src/core.sh \
        'AnyTLS ACME systemd override must use an isolated drop-in filename'
    assert_match 'systemctl daemon-reload' src/core.sh \
        'AnyTLS ACME systemd override must reload systemd after writing the drop-in'
    assert_no_match 'service\.d/override\.conf' src/core.sh \
        'AnyTLS ACME systemd helper must not overwrite override.conf'
    assert_no_match 'safe_write_file /lib/systemd/system/\$\{is_core:-sing-box\}\.service' src/core.sh \
        'AnyTLS ACME systemd helper must not rewrite the primary systemd unit file'

    : >"$log"
    TEST_SD_LOG="$log" REPO_ROOT="$REPO_ROOT" bash <<'EOF'
set -o pipefail
. "$REPO_ROOT/src/core.sh"

msg() { printf 'MSG:%s\n' "$*" >>"$TEST_SD_LOG"; }
warn() { printf 'WARN:%s\n' "$*" >>"$TEST_SD_LOG"; }
err() {
    printf 'ERR:%s\n' "$*" >>"$TEST_SD_LOG"
    return 1
}
safe_ensure_dir() {
    printf 'mkdir:%s\n' "$1" >>"$TEST_SD_LOG"
    return 0
}
safe_write_file() {
    printf 'write:%s\n' "$1" >>"$TEST_SD_LOG"
    printf 'content:%s\n' "$2" >>"$TEST_SD_LOG"
    return 0
}
systemctl() {
    printf 'systemctl:%s\n' "$*" >>"$TEST_SD_LOG"
    case "$*" in
    'show sing-box -p ProtectSystem --value')
        printf 'full\n'
        ;;
    'show sing-box -p ReadWritePaths --value')
        printf '\n'
        ;;
    'daemon-reload')
        return 0
        ;;
    esac
}

is_systemd=1
is_anytls_acme_mode=1
is_anytls_acme_data_dir=/etc/sing-box/acme
is_log_dir=/var/log/sing-box

ensure_anytls_acme_systemd_writable_paths
EOF
    assert_log_contains "$log" 'mkdir:/etc/systemd/system/sing-box.service.d' \
        'ProtectSystem=full with empty ReadWritePaths must create the service drop-in directory'
    assert_log_contains "$log" 'write:/etc/systemd/system/sing-box.service.d/10-anytls-acme.conf' \
        'ProtectSystem=full with empty ReadWritePaths must write the isolated AnyTLS ACME drop-in'
    assert_log_contains "$log" 'content:[Service]' \
        'AnyTLS ACME systemd override must render a [Service] section'
    assert_log_contains "$log" 'ReadWritePaths=/etc/sing-box/acme /var/log/sing-box' \
        'AnyTLS ACME systemd override must grant writes to ACME storage and the sing-box log directory'
    assert_log_contains "$log" 'systemctl:daemon-reload' \
        'ProtectSystem=full with empty ReadWritePaths must reload systemd after writing the drop-in'

    : >"$log"
    TEST_SD_LOG="$log" REPO_ROOT="$REPO_ROOT" bash <<'EOF'
set -o pipefail
. "$REPO_ROOT/src/core.sh"

msg() { :; }
warn() { :; }
err() {
    printf 'ERR:%s\n' "$*" >&2
    return 1
}
safe_ensure_dir() {
    printf 'mkdir:%s\n' "$1" >>"$TEST_SD_LOG"
    return 0
}
safe_write_file() {
    printf 'write:%s\n' "$1" >>"$TEST_SD_LOG"
    return 0
}
systemctl() {
    printf 'systemctl:%s\n' "$*" >>"$TEST_SD_LOG"
    case "$*" in
    'show sing-box -p ProtectSystem --value')
        printf 'strict\n'
        ;;
    'show sing-box -p ReadWritePaths --value')
        printf '\n'
        ;;
    'daemon-reload')
        return 0
        ;;
    esac
}

is_systemd=1
is_anytls_acme_mode=1
is_anytls_acme_data_dir=/etc/sing-box/acme

ensure_anytls_acme_systemd_writable_paths
EOF
    assert_log_contains "$log" 'write:/etc/systemd/system/sing-box.service.d/10-anytls-acme.conf' \
        'ProtectSystem=strict with empty ReadWritePaths must also write the AnyTLS ACME drop-in'

    : >"$log"
    TEST_SD_LOG="$log" REPO_ROOT="$REPO_ROOT" bash <<'EOF'
set -o pipefail
. "$REPO_ROOT/src/core.sh"

msg() { :; }
warn() { :; }
err() {
    printf 'ERR:%s\n' "$*" >&2
    return 1
}
safe_ensure_dir() {
    printf 'mkdir:%s\n' "$1" >>"$TEST_SD_LOG"
    return 0
}
safe_write_file() {
    printf 'write:%s\n' "$1" >>"$TEST_SD_LOG"
    return 0
}
systemctl() {
    printf 'systemctl:%s\n' "$*" >>"$TEST_SD_LOG"
    case "$*" in
    'show sing-box -p ProtectSystem --value')
        printf 'full\n'
        ;;
    'show sing-box -p ReadWritePaths --value')
        printf '/etc/sing-box/acme /var/log/sing-box\n'
        ;;
    'daemon-reload')
        return 0
        ;;
    esac
}

is_systemd=1
is_anytls_acme_mode=1
is_anytls_acme_data_dir=/etc/sing-box/acme

ensure_anytls_acme_systemd_writable_paths
EOF
    assert_log_not_contains "$log" 'write:/etc/systemd/system/sing-box.service.d/10-anytls-acme.conf' \
        'Existing ReadWritePaths entries must suppress AnyTLS ACME override rewrites'
    assert_log_not_contains "$log" 'systemctl:daemon-reload' \
        'Existing ReadWritePaths entries must skip daemon-reload'

    : >"$log"
    TEST_SD_LOG="$log" REPO_ROOT="$REPO_ROOT" bash <<'EOF'
set -o pipefail
. "$REPO_ROOT/src/core.sh"

safe_ensure_dir() {
    printf 'mkdir:%s\n' "$1" >>"$TEST_SD_LOG"
    return 0
}
safe_write_file() {
    printf 'write:%s\n' "$1" >>"$TEST_SD_LOG"
    return 0
}
systemctl() {
    printf 'systemctl:%s\n' "$*" >>"$TEST_SD_LOG"
    case "$*" in
    'show sing-box -p ProtectSystem --value')
        printf '\n'
        ;;
    'show sing-box -p ReadWritePaths --value')
        printf '\n'
        ;;
    'daemon-reload')
        return 0
        ;;
    esac
}

is_systemd=1
is_anytls_acme_mode=1
is_anytls_acme_data_dir=/etc/sing-box/acme

ensure_anytls_acme_systemd_writable_paths
EOF
    assert_log_not_contains "$log" 'write:/etc/systemd/system/sing-box.service.d/10-anytls-acme.conf' \
        'Empty ProtectSystem must skip AnyTLS ACME systemd override writes'
    assert_log_not_contains "$log" 'systemctl:daemon-reload' \
        'Empty ProtectSystem must skip daemon-reload'

    : >"$log"
    TEST_SD_LOG="$log" REPO_ROOT="$REPO_ROOT" bash <<'EOF'
set -o pipefail
. "$REPO_ROOT/src/core.sh"

safe_ensure_dir() {
    printf 'mkdir:%s\n' "$1" >>"$TEST_SD_LOG"
    return 0
}
safe_write_file() {
    printf 'write:%s\n' "$1" >>"$TEST_SD_LOG"
    return 0
}
systemctl() {
    printf 'systemctl:%s\n' "$*" >>"$TEST_SD_LOG"
    case "$*" in
    'show sing-box -p ProtectSystem --value')
        printf 'no\n'
        ;;
    'show sing-box -p ReadWritePaths --value')
        printf '\n'
        ;;
    'daemon-reload')
        return 0
        ;;
    esac
}

is_systemd=1
is_anytls_acme_mode=1
is_anytls_acme_data_dir=/etc/sing-box/acme

ensure_anytls_acme_systemd_writable_paths
EOF
    assert_log_not_contains "$log" 'write:/etc/systemd/system/sing-box.service.d/10-anytls-acme.conf' \
        'ProtectSystem=no must skip AnyTLS ACME systemd override writes'
    assert_log_not_contains "$log" 'systemctl:daemon-reload' \
        'ProtectSystem=no must skip daemon-reload'

    : >"$log"
    TEST_SD_LOG="$log" REPO_ROOT="$REPO_ROOT" bash <<'EOF'
set -o pipefail
. "$REPO_ROOT/src/core.sh"

safe_ensure_dir() {
    printf 'mkdir:%s\n' "$1" >>"$TEST_SD_LOG"
    return 0
}
safe_write_file() {
    printf 'write:%s\n' "$1" >>"$TEST_SD_LOG"
    return 0
}
systemctl() {
    printf 'systemctl:%s\n' "$*" >>"$TEST_SD_LOG"
    return 0
}

unset is_systemd
is_anytls_acme_mode=1
is_anytls_acme_data_dir=/etc/sing-box/acme

ensure_anytls_acme_systemd_writable_paths
EOF
    assert_log_not_contains "$log" 'write:/etc/systemd/system/sing-box.service.d/10-anytls-acme.conf' \
        'Non-systemd environments must skip AnyTLS ACME systemd override writes'
    assert_log_not_contains "$log" 'systemctl:' \
        'Non-systemd environments must not query systemctl'

    : >"$log"
    TEST_SD_LOG="$log" REPO_ROOT="$REPO_ROOT" bash <<'EOF'
set -o pipefail
. "$REPO_ROOT/src/core.sh"

safe_ensure_dir() {
    printf 'mkdir:%s\n' "$1" >>"$TEST_SD_LOG"
    return 0
}
safe_write_file() {
    printf 'write:%s\n' "$1" >>"$TEST_SD_LOG"
    return 0
}
systemctl() {
    printf 'systemctl:%s\n' "$*" >>"$TEST_SD_LOG"
    return 0
}

is_systemd=1
unset is_anytls_acme_mode
is_anytls_acme_data_dir=/etc/sing-box/acme

ensure_anytls_acme_systemd_writable_paths
EOF
    assert_log_not_contains "$log" 'write:/etc/systemd/system/sing-box.service.d/10-anytls-acme.conf' \
        'Non-AnyTLS ACME flows must skip systemd override writes'
    assert_log_not_contains "$log" 'systemctl:' \
        'Non-AnyTLS ACME flows must not query systemctl'

    : >"$log"
    TEST_SD_LOG="$log" REPO_ROOT="$REPO_ROOT" bash <<'EOF'
set -o pipefail
. "$REPO_ROOT/src/core.sh"

msg() { printf 'MSG:%s\n' "$*" >>"$TEST_SD_LOG"; }
warn() { printf 'WARN:%s\n' "$*" >>"$TEST_SD_LOG"; }
err() {
    printf 'ERR:%s\n' "$*" >>"$TEST_SD_LOG"
    return 1
}
safe_ensure_dir() {
    printf 'mkdir:%s\n' "$1" >>"$TEST_SD_LOG"
    return 0
}
safe_write_file() {
    printf 'write:%s\n' "$1" >>"$TEST_SD_LOG"
    return 0
}
systemctl() {
    printf 'systemctl:%s\n' "$*" >>"$TEST_SD_LOG"
    case "$*" in
    'show sing-box -p ProtectSystem --value')
        printf 'full\n'
        ;;
    'show sing-box -p ReadWritePaths --value')
        printf '\n'
        ;;
    'daemon-reload')
        return 1
        ;;
    esac
}

is_systemd=1
is_anytls_acme_mode=1
is_anytls_acme_data_dir=/etc/sing-box/acme

ensure_anytls_acme_systemd_writable_paths && exit 1
EOF
    assert_log_contains "$log" 'write:/etc/systemd/system/sing-box.service.d/10-anytls-acme.conf' \
        'daemon-reload failure path must still write the AnyTLS ACME drop-in before failing'
    assert_log_contains "$log" 'systemctl:daemon-reload' \
        'daemon-reload failure path must attempt a systemd reload'
    assert_log_contains "$log" 'ERR:systemd daemon-reload 失败，无法应用 AnyTLS ACME 可写路径 override。' \
        'daemon-reload failure path must return a concrete AnyTLS ACME systemd error'

    : >"$log"
    TEST_SD_LOG="$log" REPO_ROOT="$REPO_ROOT" bash <<'EOF'
set -o pipefail
. "$REPO_ROOT/src/core.sh"

msg() { printf 'MSG:%s\n' "$*" >>"$TEST_SD_LOG"; }
warn() { printf 'WARN:%s\n' "$*" >>"$TEST_SD_LOG"; }
err() {
    printf 'ERR:%s\n' "$*" >>"$TEST_SD_LOG"
    return 1
}
begin_backup_transaction_if_needed() {
    printf 'begin\n' >>"$TEST_SD_LOG"
    IS_BACKUP_ACTIVE=true
    return 0
}
finalize_backup_transaction() {
    printf 'finalize\n' >>"$TEST_SD_LOG"
    IS_BACKUP_ACTIVE=false
    return 0
}
check_pending_server_config() {
    printf 'check\n' >>"$TEST_SD_LOG"
    return 0
}
render_server_config_json() {
    printf '%s\n' '{"log":{}}'
}
safe_ensure_dir() {
    printf 'mkdir:%s\n' "$1" >>"$TEST_SD_LOG"
    return 0
}
safe_write_file() {
    printf 'write:%s\n' "$1" >>"$TEST_SD_LOG"
    return 0
}
restart_core_and_verify() {
    printf 'restart\n' >>"$TEST_SD_LOG"
    return 0
}
rollback_latest_backup() {
    printf 'rollback:%s\n' "$*" >>"$TEST_SD_LOG"
    return 0
}
systemctl() {
    printf 'systemctl:%s\n' "$*" >>"$TEST_SD_LOG"
    case "$*" in
    'show sing-box -p ProtectSystem --value')
        printf 'full\n'
        ;;
    'show sing-box -p ReadWritePaths --value')
        printf '\n'
        ;;
    'daemon-reload')
        return 1
        ;;
    esac
}

IS_BACKUP_ACTIVE=false
is_systemd=1
is_anytls_acme_mode=1
is_config_json=/etc/sing-box/config.json
is_anytls_acme_data_dir=/etc/sing-box/acme
is_json_file=/etc/sing-box/conf/AnyTLS-example.com.json
is_new_json='{"inbounds":[]}'

commit_server_config_with_validation && exit 1
EOF
    assert_order '^check$' '^begin$' "$log" \
        'systemd sandbox failure path must still validate before opening the transaction'
    assert_order '^begin$' '^mkdir:/etc/sing-box/acme$' "$log" \
        'systemd sandbox failure path must create the ACME data directory inside the transaction'
    assert_order '^mkdir:/etc/sing-box/acme$' '^write:/etc/systemd/system/sing-box.service.d/10-anytls-acme.conf$' "$log" \
        'systemd sandbox failure path must write the drop-in after ensuring the ACME data directory'
    assert_order '^write:/etc/systemd/system/sing-box.service.d/10-anytls-acme.conf$' '^finalize$' "$log" \
        'systemd sandbox failure path must finalize the active transaction after writing the drop-in'
    assert_order '^finalize$' '^rollback:--yes$' "$log" \
        'systemd sandbox failure path must finalize before rollback'
    assert_log_not_contains "$log" 'write:/etc/sing-box/conf/AnyTLS-example.com.json' \
        'systemd sandbox failure path must not continue to write the AnyTLS inbound after daemon-reload fails'
    assert_log_not_contains "$log" 'restart' \
        'systemd sandbox failure path must not restart sing-box after daemon-reload fails'

    : >"$log"
    TEST_SD_LOG="$log" REPO_ROOT="$REPO_ROOT" bash <<'EOF'
set -o pipefail
. "$REPO_ROOT/src/core.sh"

msg() { printf 'MSG:%s\n' "$*" >>"$TEST_SD_LOG"; }
warn() { printf 'WARN:%s\n' "$*" >>"$TEST_SD_LOG"; }
err() {
    printf 'ERR:%s\n' "$*" >>"$TEST_SD_LOG"
    return 1
}
begin_backup_transaction_if_needed() {
    printf 'begin\n' >>"$TEST_SD_LOG"
    IS_BACKUP_ACTIVE=true
    return 0
}
finalize_backup_transaction() {
    printf 'finalize\n' >>"$TEST_SD_LOG"
    IS_BACKUP_ACTIVE=false
    return 0
}
check_pending_server_config() {
    printf 'check\n' >>"$TEST_SD_LOG"
    return 0
}
render_server_config_json() {
    printf '%s\n' '{"log":{}}'
}
safe_ensure_dir() {
    printf 'mkdir:%s\n' "$1" >>"$TEST_SD_LOG"
    return 0
}
safe_write_file() {
    printf 'write:%s\n' "$1" >>"$TEST_SD_LOG"
    return 0
}
restart_core_and_verify() {
    printf 'restart\n' >>"$TEST_SD_LOG"
    return 1
}
rollback_latest_backup() {
    printf 'rollback:%s\n' "$*" >>"$TEST_SD_LOG"
    return 0
}
systemctl() {
    printf 'systemctl:%s\n' "$*" >>"$TEST_SD_LOG"
    case "$*" in
    'show sing-box -p ProtectSystem --value')
        printf 'full\n'
        ;;
    'show sing-box -p ReadWritePaths --value')
        printf '\n'
        ;;
    'daemon-reload')
        return 0
        ;;
    esac
}

IS_BACKUP_ACTIVE=false
is_systemd=1
is_anytls_acme_mode=1
is_config_json=/etc/sing-box/config.json
is_anytls_acme_data_dir=/etc/sing-box/acme
is_json_file=/etc/sing-box/conf/AnyTLS-example.com.json
is_new_json='{"inbounds":[]}'

commit_server_config_with_validation && exit 1
EOF
    assert_order '^check$' '^begin$' "$log" \
        'restart rollback path with systemd sandbox must validate before the transaction begins'
    assert_order '^mkdir:/etc/sing-box/acme$' '^write:/etc/systemd/system/sing-box.service.d/10-anytls-acme.conf$' "$log" \
        'restart rollback path with systemd sandbox must write the drop-in after the ACME directory exists'
    assert_order '^write:/etc/systemd/system/sing-box.service.d/10-anytls-acme.conf$' '^write:/etc/sing-box/conf/AnyTLS-example.com.json$' "$log" \
        'restart rollback path with systemd sandbox must write the drop-in before the AnyTLS inbound file'
    assert_order '^write:/etc/sing-box/conf/AnyTLS-example.com.json$' '^restart$' "$log" \
        'restart rollback path with systemd sandbox must restart only after writing the AnyTLS inbound file'
    assert_order '^restart$' '^finalize$' "$log" \
        'restart rollback path with systemd sandbox must finalize after restart failure is observed'
    assert_order '^finalize$' '^rollback:--yes$' "$log" \
        'restart rollback path with systemd sandbox must finalize before rollback'
}

run_version_compare_checks() {
    REPO_ROOT="$REPO_ROOT" bash <<'EOF'
set -o pipefail
. "$REPO_ROOT/src/core.sh"

is_core_version_ge 1.13.8 1.12.0
is_core_version_ge v1.13.8 1.12.0
is_core_version_ge 1.12.0 1.12.0
! is_core_version_ge 1.11.9 1.12.0
is_core_version_ge 1.14.1 1.14.0
! is_core_version_ge 1.13.9 1.14.0
is_core_version_ge 2.0.0 1.14.0
is_core_version_ge 1.14 1.14.0
is_core_version_ge 1.14.0-alpha 1.14.0
EOF
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
assert_match 'render_pending_server_config_json' src/core.sh \
    'AnyTLS ACME validation must render a temporary base config when config.json is missing'
assert_match 'check -c "\$tmp_config_json" -C "\$tmp_conf_dir"' src/core.sh \
    'AnyTLS ACME validation must check against a temporary config.json instead of the production path'
assert_match 'load firewall\.sh' src/core.sh \
    'AnyTLS ACME preflight must load the dedicated firewall module'
assert_no_match 'sort -V' src/core.sh \
    'version comparison must not depend on GNU sort -V'
assert_match 'run: bash tests/anytls-acme-transaction\.sh' .github/workflows/release.yml \
    'release workflow must run AnyTLS ACME transaction checks before packaging'
assert_order 'run: bash tests/anytls-acme-transaction\.sh' '- name: tar' .github/workflows/release.yml \
    'release workflow AnyTLS ACME transaction checks must run before tar packaging'

run_schema_generation_checks
run_firewall_checks
run_transaction_checks
run_systemd_sandbox_checks
run_version_compare_checks
run_acme_capability_check

printf '[PASS] AnyTLS ACME transaction checks\n'
