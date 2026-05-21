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

assert_not_match() {
    local pattern=$1
    local file=$2
    local description=$3

    if command -v rg >/dev/null 2>&1; then
        rg -n -- "$pattern" "$file" >/dev/null && fail "$description"
    else
        grep -En "$pattern" "$file" >/dev/null && fail "$description"
    fi
}

assert_contains() {
    local haystack=$1
    local needle=$2
    local description=$3
    [[ $haystack == *"$needle"* ]] || fail "$description"
}

assert_contains_file() {
    local needle=$1
    local file=$2
    local description=$3
    grep -Fq -- "$needle" "$file" || fail "$description"
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TUIC_FILE="$REPO_ROOT/src/tuic.sh"

bash -n "$TUIC_FILE" || fail "src/tuic.sh syntax must be valid"

for fn in \
    tuic_menu_select_config \
    tuic_menu_change_config \
    tuic_menu_select_hop_action
do
    assert_match "^${fn}\\(\\)" "$TUIC_FILE" "missing TUIC menu helper: $fn"
done
pass "TUIC menu change helper functions are locatable"

for label in \
    "修改 UDP 监听端口" \
    "重新生成 UUID" \
    "重新生成 Password" \
    "修改 Domain + ACME" \
    "修改 Domain + file-cert" \
    "切换为 Self-signed insecure" \
    "修改 Congestion Control"
do
    assert_contains_file "$label" "$TUIC_FILE" "TUIC change menu should include: $label"
done
pass "TUIC change menu exposes expected actions"

assert_match 'tuic_menu_select_config "查看 TUIC 客户端 URL"' "$TUIC_FILE" \
    "TUIC URL menu should ask the user to select a config"
assert_match 'tuic_url "\$config"' "$TUIC_FILE" \
    "TUIC URL menu should call tuic_url with the selected config"
assert_match 'tuic_menu_change_config' "$TUIC_FILE" \
    "TUIC menu option should call the change flow"
assert_not_match '菜单修改入口为最小占位' "$TUIC_FILE" \
    "TUIC menu change entry should no longer be a placeholder"

assert_match 'tuic_menu_select_hop_action "\$config" "\$old_port" "\$new_port"' "$TUIC_FILE" \
    "port change menu should detect and select associated hop action"
assert_match '检测到当前 TUIC 配置存在 Port-Hopping 实例' "$TUIC_FILE" \
    "port change menu should tell the user when hop exists"
assert_match '迁移 Port-Hopping 到新端口' "$TUIC_FILE" \
    "port change menu should offer hop migration"
assert_match '删除旧 Port-Hopping' "$TUIC_FILE" \
    "port change menu should offer hop deletion"
assert_match '保留旧 Port-Hopping' "$TUIC_FILE" \
    "port change menu should offer keep-with-risk"
assert_match 'tuic_change "\$config" --port "\$new_port" "\$\{hop_args\[@\]\}"' "$TUIC_FILE" \
    "port change menu should delegate to tuic_change with --hop-action"
assert_match 'tuic_change "\$config" --uuid auto' "$TUIC_FILE" \
    "UUID regeneration should delegate to tuic_change"
assert_match 'tuic_change "\$config" --password auto' "$TUIC_FILE" \
    "password regeneration should delegate to tuic_change"
assert_match 'tuic_change "\$config" --domain "\$domain" --tls acme' "$TUIC_FILE" \
    "Domain + ACME should delegate to tuic_change"
assert_match 'tuic_change "\$config" --domain "\$domain" --cert-file "\$cert_path" --key-file "\$key_path"' "$TUIC_FILE" \
    "file-cert change should delegate to tuic_change"
assert_match 'tuic_change "\$config" --insecure' "$TUIC_FILE" \
    "self-signed insecure change should delegate to tuic_change"
assert_match 'tuic_change "\$config" --cc "\$cc"' "$TUIC_FILE" \
    "congestion control change should delegate to tuic_change"
pass "TUIC change menu delegates to structured lifecycle"

dynamic_output=$(bash -c '
    set -euo pipefail
    repo_root=$1
    test_root=$(mktemp -d "${TMPDIR:-/tmp}/tuic-menu-select.XXXXXX")
    trap "rm -rf \"$test_root\"" EXIT
    is_conf_dir="$test_root/conf"
    mkdir -p "$is_conf_dir"
    cp "$repo_root/tests/fixtures/tuic/tuic-ip-insecure.json" "$is_conf_dir/tuic-a.json"
    cp "$repo_root/tests/fixtures/tuic/tuic-domain-provider.json" "$is_conf_dir/tuic-b.json"
    export TUIC_HOP_BASE_DIR="$test_root/hop"
    export TUIC_HOP_INSTANCE_DIR="$TUIC_HOP_BASE_DIR/instances"
    export TUIC_HOP_NFT_RULE_DIR="$test_root/nft"
    export TUIC_HOP_SKIP_SYSTEMD=1
    export TUIC_HOP_SKIP_NFT=1
    export TUIC_HOP_SKIP_UFW=1
    mkdir -p "$TUIC_HOP_INSTANCE_DIR" "$TUIC_HOP_NFT_RULE_DIR"
    ui_print() { printf "%s\n" "$*"; }
    ui_warn() { printf "[WARN] %s\n" "$*" >&2; }
    ui_error() { printf "[ERROR] %s\n" "$*" >&2; }
    ui_blank() { printf "\n"; }
    ui_dim() { printf "%s\n" "$*"; }
    ui_kv() { printf "%s %s\n" "$1" "${2:-}"; }
    ui_menu_item() { printf " %2s. %s\n" "$1" "$2"; }
    ui_read_raw() {
        local target=$1 prompt=$2 value
        printf "%s" "$prompt"
        IFS= read -r value
        printf -v "$target" "%s" "$value"
    }
    . "$repo_root/src/cert.sh"
    . "$repo_root/src/tuic_port_hopping.sh"
    . "$repo_root/src/tuic.sh"
    tuic_menu_select_config "测试选择" < <(printf "2\n")
    printf "selected=%s\n" "${tuic_menu_selected_config:-unset}"
' bash "$REPO_ROOT") || fail "tuic_menu_select_config dynamic selection should run"

assert_contains "$dynamic_output" "selected=tuic-b.json" \
    "tuic_menu_select_config should store the selected config basename"
pass "TUIC menu config selection returns the selected config"
