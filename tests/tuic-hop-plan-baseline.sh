#!/usr/bin/env bash
set -o pipefail

fail() {
    printf '[FAIL] %s\n' "$1" >&2
    exit 1
}

pass() {
    printf '[PASS] %s\n' "$1"
}

assert_match() {
    local pattern=$1
    local file=$2
    local description=$3

    if command -v rg >/dev/null 2>&1; then
        rg -n -- "$pattern" "$file" >/dev/null || fail "$description"
    else
        grep -En "$pattern" "$file" >/dev/null || fail "$description"
    fi
}

assert_contains() {
    local haystack=$1
    local needle=$2
    local description=$3
    [[ $haystack == *"$needle"* ]] || fail "$description"
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TUIC_FILE="$REPO_ROOT/src/tuic.sh"

bash -n "$TUIC_FILE" || fail "src/tuic.sh syntax must be valid"

for fn in \
    tuic_build_hop_change_plan \
    tuic_show_hop_change_plan \
    tuic_confirm_hop_change_plan \
    tuic_execute_hop_change_plan
do
    assert_match "^${fn}\\(\\)" "$TUIC_FILE" "missing hop plan helper: $fn"
done
pass "TUIC hop plan helper functions are locatable"

assert_match 'TUIC Port-Hopping 变更计划' "$TUIC_FILE" \
    "change plan should have a visible title"
assert_match 'TUIC 删除计划' "$TUIC_FILE" \
    "delete plan should have a visible title"
assert_match 'MIGRATE-HOP' "$TUIC_FILE" \
    "migrate action should have a token"
assert_match 'DELETE-HOP' "$TUIC_FILE" \
    "delete hop action should have a token"
assert_match 'KEEP-HOP' "$TUIC_FILE" \
    "keep hop action should have a token"
assert_match 'DELETE-TUIC' "$TUIC_FILE" \
    "delete TUIC action should have a token"
with_hop_block=$(awk '/--with-hop\)/,/;;/' "$TUIC_FILE")
assert_contains "$with_hop_block" "tuic_hop_action=delete" \
    "--with-hop should be equivalent to --hop-action delete"
assert_match '残留风险' "$TUIC_FILE" \
    "keep action should warn about residual risk"
pass "TUIC hop plan static semantics are locatable"

plan_output=$(bash -c '
    set -euo pipefail
    repo_root=$1
    test_root=$(mktemp -d "${TMPDIR:-/tmp}/tuic-hop-plan.XXXXXX")
    trap "rm -rf \"$test_root\"" EXIT
    export TUIC_HOP_BASE_DIR="$test_root/etc/tuic-port-hopping"
    export TUIC_HOP_INSTANCE_DIR="$TUIC_HOP_BASE_DIR/instances"
    export TUIC_HOP_NFT_RULE_DIR="$test_root/etc/nftables.d"
    export TUIC_HOP_APPLY_SCRIPT="$test_root/usr/local/sbin/apply-tuic-port-hopping.sh"
    export TUIC_HOP_SYSTEMD_TEMPLATE="$test_root/etc/systemd/system/tuic-port-hopping@.service"
    export TUIC_HOP_SKIP_SYSTEMD=1
    export TUIC_HOP_SKIP_NFT=1
    export TUIC_HOP_SKIP_UFW=1
    mkdir -p "$TUIC_HOP_INSTANCE_DIR" "$TUIC_HOP_NFT_RULE_DIR"
    ui_print() { printf "%s\n" "$*"; }
    ui_warn() { printf "[WARN] %s\n" "$*" >&2; }
    ui_error() { printf "[ERROR] %s\n" "$*" >&2; }
    ui_blank() { printf "\n"; }
    ui_kv() { printf "%s %s\n" "$1" "${2:-}"; }
    ui_confirm_token() { return 0; }
    . "$repo_root/src/cert.sh"
    . "$repo_root/src/tuic_port_hopping.sh"
    . "$repo_root/src/tuic.sh"
    tuic_hop_render_instance_env 443 10443 10542 30 >"$TUIC_HOP_INSTANCE_DIR/443.env"
    tuic_config_name=tuic-example.com.json
    tuic_config_file=/etc/sing-box/conf/tuic-example.com.json
    tuic_build_hop_change_plan change 443 8443 migrate
    tuic_show_hop_change_plan
    tuic_build_hop_change_plan delete 443 443 delete
    tuic_show_hop_change_plan
' bash "$REPO_ROOT") || fail "hop plan dynamic output should render"

assert_contains "$plan_output" "TUIC Port-Hopping 变更计划" \
    "change plan output should include title"
assert_contains "$plan_output" "旧真实端口" \
    "change plan output should include old port label"
assert_contains "$plan_output" "443/udp" \
    "change plan output should include old real port"
assert_contains "$plan_output" "新真实端口" \
    "change plan output should include new port label"
assert_contains "$plan_output" "8443/udp" \
    "change plan output should include new real port"
assert_contains "$plan_output" "10443-10542/udp" \
    "plan output should include old hopping range"
assert_contains "$plan_output" "处理方式" \
    "plan output should include action"
assert_contains "$plan_output" "migrate" \
    "change plan output should include migrate action"
assert_contains "$plan_output" "TUIC 删除计划" \
    "delete plan output should include title"
assert_contains "$plan_output" "delete: 先删除 hop 实例，再删除 TUIC config" \
    "delete plan should describe delete execution order"
pass "TUIC hop plan dynamic output includes ports, range, and actions"
