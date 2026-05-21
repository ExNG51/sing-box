#!/usr/bin/env bash
set -o pipefail

fail() {
    printf '[FAIL] %s\n' "$1" >&2
    exit 1
}

pass() {
    printf '[PASS] %s\n' "$1"
}

assert_file() {
    local file=$1
    [ -f "$file" ] || fail "missing file: $file"
}

assert_function() {
    local name=$1
    type "$name" >/dev/null 2>&1 || fail "missing function: $name"
}

assert_contains() {
    local haystack=$1
    local needle=$2
    local description=$3
    [[ $haystack == *"$needle"* ]] || fail "$description"
}

assert_not_contains() {
    local haystack=$1
    local needle=$2
    local description=$3
    [[ $haystack != *"$needle"* ]] || fail "$description"
}

assert_match_file() {
    local pattern=$1
    local file=$2
    local description=$3

    if command -v rg >/dev/null 2>&1; then
        rg -n "$pattern" "$file" >/dev/null || fail "$description"
    else
        grep -En "$pattern" "$file" >/dev/null || fail "$description"
    fi
}

assert_not_match_file() {
    local pattern=$1
    local file=$2
    local description=$3

    if command -v rg >/dev/null 2>&1; then
        rg -n "$pattern" "$file" >/dev/null && fail "$description"
    else
        grep -En "$pattern" "$file" >/dev/null && fail "$description"
    fi
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/sing-box-tuic-hop-test.XXXXXX")" || fail "failed to create temp root"
trap 'rm -rf "$TEST_ROOT"' EXIT

export TUIC_HOP_BASE_DIR="$TEST_ROOT/etc/tuic-port-hopping"
export TUIC_HOP_INSTANCE_DIR="$TUIC_HOP_BASE_DIR/instances"
export TUIC_HOP_NFT_RULE_DIR="$TEST_ROOT/etc/nftables.d"
export TUIC_HOP_APPLY_SCRIPT="$TEST_ROOT/usr/local/sbin/apply-tuic-port-hopping.sh"
export TUIC_HOP_SYSTEMD_TEMPLATE="$TEST_ROOT/etc/systemd/system/tuic-port-hopping@.service"
export TUIC_HOP_SKIP_SYSTEMD=1
export TUIC_HOP_SKIP_NFT=1
export TUIC_HOP_SKIP_UFW=1

is_core=sing-box
is_core_dir="$TEST_ROOT/etc/sing-box"
is_conf_dir="$is_core_dir/conf"
is_config_json="$is_core_dir/config.json"
is_backup_dir="$is_core_dir/backups"
is_caddyfile="$TEST_ROOT/etc/caddy/Caddyfile"
is_caddy_conf="$TEST_ROOT/etc/caddy/conf"
is_core_bin="$TEST_ROOT/usr/local/bin/sing-box"
is_sh_bin="$TEST_ROOT/usr/local/bin/sb"
is_shell_profile="$TEST_ROOT/root/.bashrc"

ui_print() { printf '%s\n' "$*"; }
ui_warn() { printf '[WARN] %s\n' "$*" >&2; }
ui_error() { printf '[ERROR] %s\n' "$*" >&2; }
ui_dim() { printf '%s\n' "$*"; }
ui_blank() { printf '\n'; }
ui_kv() { printf '%s %s\n' "$1" "${2:-}"; }

assert_file "$REPO_ROOT/src/backup.sh"
assert_file "$REPO_ROOT/src/tuic_port_hopping.sh"

# shellcheck source=/dev/null
source "$REPO_ROOT/src/backup.sh"
# shellcheck source=/dev/null
source "$REPO_ROOT/src/tuic_port_hopping.sh"

for fn in \
    tuic_hop_calculate_auto_range \
    tuic_hop_validate_range \
    tuic_hop_check_instance_port_conflict \
    tuic_hop_render_instance_env \
    tuic_hop_render_nft_rule \
    tuic_hop_render_systemd_template \
    tuic_hop_show_client_hint \
    tuic_hop_precheck_remove_paths \
    tuic_hop_migrate_instance \
    tuic_hop_delete_instance
do
    assert_function "$fn"
done
pass "TUIC port-hopping module exposes required API"

auto_range=$(tuic_hop_calculate_auto_range 443)
range_start=${auto_range%-*}
range_end=${auto_range#*-}
[[ $range_start =~ ^[0-9]+$ && $range_end =~ ^[0-9]+$ ]] || fail "auto range should be numeric"
[[ $range_start -ge 1 && $range_end -le 65535 ]] || fail "auto range should stay in valid port bounds"
[[ $range_start -le 443 && 443 -le $range_end ]] && fail "auto range must not contain REAL_PORT"
[[ $((range_end - range_start + 1)) -eq 100 ]] || fail "auto range should contain 100 ports"
pass "auto range avoids REAL_PORT and has default size"

mkdir -p "$TUIC_HOP_INSTANCE_DIR"
tuic_hop_render_instance_env 443 10443 10542 30 >"$TUIC_HOP_INSTANCE_DIR/443.env"
tuic_hop_validate_range 443 10443 10542 || fail "valid range should pass"
tuic_hop_validate_range 443 440 450 >/dev/null 2>&1 && fail "range containing REAL_PORT should fail"
tuic_hop_check_instance_port_conflict 8443 10500 10599 >/dev/null 2>&1 && fail "overlapping instance range should fail"
tuic_hop_check_instance_port_conflict 8443 400 500 >/dev/null 2>&1 && fail "range containing another REAL_PORT should fail"
tuic_hop_check_instance_port_conflict 10500 20000 20099 >/dev/null 2>&1 && fail "REAL_PORT inside another range should fail"
pass "range conflict detection rejects overlaps and real-port collisions"

nft_rule=$(tuic_hop_render_nft_rule 443 10443 10542)
assert_contains "$nft_rule" "table inet tuic_hopping_443" "nft render should include per-instance table"
assert_contains "$nft_rule" "udp dport 10443-10542 redirect to :443" "nft render should redirect UDP range to REAL_PORT"
assert_not_contains "$nft_rule" "tcp dport" "nft render must not include TCP rules"
assert_not_contains "$nft_rule" "flush ruleset" "nft render must not flush global ruleset"
pass "nft rule render is scoped to UDP range and instance table"

systemd_template=$(tuic_hop_render_systemd_template)
assert_contains "$systemd_template" "$TUIC_HOP_APPLY_SCRIPT %i" "systemd template should call apply script with %i"
assert_contains "$systemd_template" "%i" "systemd template should use instance placeholder"
assert_not_contains "$systemd_template" "tuic-port-hopping@443" "systemd template must not hardcode one port"
pass "systemd template render is instance-generic"

hint=$(tuic_hop_show_client_hint 443)
assert_contains "$hint" "port-hopping" "client hint should include port-hopping option"
assert_contains "$hint" "443;10443-10542" "client hint should include REAL_PORT and range"
assert_not_contains "$hint" "UUID" "client hint must not expose UUID"
assert_not_contains "$hint" "password" "client hint must not expose password"
pass "client hint includes hopping parameters without credentials"

mkdir -p "$(dirname "$TUIC_HOP_APPLY_SCRIPT")" "$(dirname "$TUIC_HOP_SYSTEMD_TEMPLATE")" "$TUIC_HOP_NFT_RULE_DIR"
printf 'apply\n' >"$TUIC_HOP_APPLY_SCRIPT"
printf 'service\n' >"$TUIC_HOP_SYSTEMD_TEMPLATE"
printf '%s\n' "$nft_rule" >"$(tuic_hop_get_nft_rule_file 443)"
init_backup_transaction tuic-hop-delete-test
tuic_hop_delete_instance 443 --yes >/tmp/tuic-hop-delete.out || fail "delete instance should succeed against temp paths"
finalize_backup_transaction
[[ ! -e "$TUIC_HOP_INSTANCE_DIR/443.env" ]] || fail "delete should remove instance env"
[[ ! -e "$(tuic_hop_get_nft_rule_file 443)" ]] || fail "delete should remove nft rule file"
pass "delete instance removes only per-instance managed files"

order_log="$TEST_ROOT/delete-order.log"
mock_bin="$TEST_ROOT/mock-bin"
mkdir -p "$mock_bin"
cat >"$mock_bin/systemctl" <<'MOCK_SYSTEMCTL'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"$ACTION_LOG"
exit 0
MOCK_SYSTEMCTL
cat >"$mock_bin/nft" <<'MOCK_NFT'
#!/usr/bin/env bash
printf 'nft %s\n' "$*" >>"$ACTION_LOG"
exit 0
MOCK_NFT
chmod +x "$mock_bin/systemctl" "$mock_bin/nft"
(
    export PATH="$mock_bin:$PATH"
    export ACTION_LOG="$order_log"
    unset TUIC_HOP_SKIP_SYSTEMD TUIC_HOP_SKIP_NFT
    : >"$ACTION_LOG"
    assert_safe_remove_path() {
        printf 'precheck %s\n' "$1" >>"$ACTION_LOG"
        return 0
    }
    safe_remove_path() {
        printf 'safe_remove %s\n' "$*" >>"$ACTION_LOG"
        return 0
    }
    tuic_hop_render_instance_env 2443 12443 12542 30 >"$TUIC_HOP_INSTANCE_DIR/2443.env"
    printf '%s\n' "$nft_rule" >"$(tuic_hop_get_nft_rule_file 2443)"
    tuic_hop_delete_instance 2443 --yes >/tmp/tuic-hop-delete-order.out
) || fail "delete order test should run with mocked system tools"
precheck_line=$(grep -n '^precheck ' "$order_log" | head -n 1 | cut -d: -f1)
systemctl_line=$(grep -n '^systemctl disable --now tuic-port-hopping@2443\.service' "$order_log" | head -n 1 | cut -d: -f1)
nft_delete_line=$(grep -n '^nft delete table inet tuic_hopping_2443' "$order_log" | head -n 1 | cut -d: -f1)
safe_remove_line=$(grep -n '^safe_remove ' "$order_log" | head -n 1 | cut -d: -f1)
[[ $precheck_line && $systemctl_line && $nft_delete_line && $safe_remove_line ]] || fail "delete order log should include precheck, systemctl, nft delete, and safe remove"
[[ $precheck_line -lt $systemctl_line && $precheck_line -lt $nft_delete_line ]] || fail "safe remove precheck must run before systemd/nft mutation"
[[ $systemctl_line -lt $safe_remove_line && $nft_delete_line -lt $safe_remove_line ]] || fail "safe remove should run after systemd/nft mutation"
pass "delete instance prechecks safe remove paths before systemd/nft mutation"

migrate_body=$(sed -n '/^tuic_hop_migrate_instance()/,/^}/p' "$REPO_ROOT/src/tuic_port_hopping.sh")
assert_contains "$migrate_body" 'tuic_hop_create_or_update_instance "$new_port"' \
    "migrate implementation should create the new instance"
assert_contains "$migrate_body" 'tuic_hop_delete_instance "$old_port" --yes' \
    "migrate implementation should delete the old instance after new validation"
create_line=$(grep -nF 'tuic_hop_create_or_update_instance "$new_port"' <<<"$migrate_body" | head -n 1 | cut -d: -f1)
delete_line=$(grep -nF 'tuic_hop_delete_instance "$old_port" --yes' <<<"$migrate_body" | head -n 1 | cut -d: -f1)
[[ $create_line && $delete_line && $create_line -lt $delete_line ]] || fail "migrate implementation must create the new instance before deleting the old instance"
pass "migrate implementation creates new instance before deleting old instance"

if safe_remove_path /etc >/tmp/tuic-hop-safe-remove.out 2>&1; then
    fail "safe_remove_path must reject broad /etc removal"
fi
if safe_remove_path "$TEST_ROOT/etc/nftables.d" >/tmp/tuic-hop-safe-remove.out 2>&1; then
    fail "safe_remove_path must reject broad nftables.d directory removal"
fi
pass "safe remove rejects broad system and nftables paths"

assert_not_match_file 'rm -rf /etc|rm -rf /etc/systemd|rm -rf /etc/nftables\.d|nft flush ruleset|iptables -F|ufw reset|systemctl disable --now tuic-port-hopping@\*\.service' "$REPO_ROOT/src/tuic_port_hopping.sh" \
    "port-hopping module must not contain dangerous broad operations"
assert_not_match_file 'HY2.*[Hh]op|hy2.*[Hh]op|hysteria.*[Hh]op|Hysteria.*[Hh]op' "$REPO_ROOT/src/tuic_port_hopping.sh" \
    "Task D must not add HY2 hopping integration"
pass "static safety and Task D boundary checks pass"
