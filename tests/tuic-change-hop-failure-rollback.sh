#!/usr/bin/env bash
 set -euo pipefail

 # 回归 P1-01：tuic_change 端口变更后 hop 步骤失败时，必须回滚已 finalize 的 TUIC 配置事务
 # 到旧端口内容，并报告 hop 残留。本测试以 mock 路径 source backup.sh + tuic.sh，
 # 注入一个会失败的 tuic_apply_hop_change_action，断言 TUIC 配置被还原且残留被报告。

 fail() {
     printf '[FAIL] %s\n' "$1" >&2
     exit 1
 }

 assert_file_content() {
     local file=$1
     local expected=$2
     local description=$3
     local actual

     [[ -f $file ]] || fail "$description (file missing: $file)"
     actual=$(cat "$file")
     [[ $actual == "$expected" ]] || fail "$description (expected: $expected, actual: $actual)"
 }

 assert_contains() {
     local file=$1
     local text=$2
     local description=$3

     grep -Fq -- "$text" "$file" || {
         [[ -f $file ]] && cat "$file" >&2
         fail "$description"
     }
 }

 REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
 TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/sing-box-tuic-hop-fail.XXXXXX")"
 trap 'rm -rf "$TEST_ROOT"' EXIT

 is_core=sing-box
 is_core_name=sing-box
 is_core_dir="$TEST_ROOT/etc/sing-box"
 is_conf_dir="$is_core_dir/conf"
 is_config_json="$is_core_dir/config.json"
 is_backup_dir="$is_core_dir/backups"
 is_caddyfile="$TEST_ROOT/etc/caddy/Caddyfile"
 is_caddy_conf="$TEST_ROOT/etc/caddy/conf"
 is_core_bin="$TEST_ROOT/usr/local/bin/sing-box"
 is_sh_bin="$TEST_ROOT/usr/local/bin/sb"
 is_shell_profile="$TEST_ROOT/root/.bashrc"
 is_log_dir="$TEST_ROOT/var/log/sing-box"
 IS_BACKUP_ROLLBACK_SKIP_SERVICES=true

 # hop 模块路径指向临时目录；跳过真实 systemd/nft/ufw。
 hop_root="$TEST_ROOT"
 TUIC_HOP_BASE_DIR="$hop_root/etc/tuic-port-hopping"
 TUIC_HOP_INSTANCE_DIR="$TUIC_HOP_BASE_DIR/instances"
 TUIC_HOP_NFT_RULE_DIR="$hop_root/etc/nftables.d"
 TUIC_HOP_APPLY_SCRIPT="$hop_root/usr/local/sbin/apply-tuic-port-hopping.sh"
 TUIC_HOP_SYSTEMD_TEMPLATE="$hop_root/etc/systemd/system/tuic-port-hopping@.service"
 TUIC_HOP_SKIP_SYSTEMD=1
 TUIC_HOP_SKIP_NFT=1
 TUIC_HOP_SKIP_UFW=1
 export TUIC_HOP_BASE_DIR TUIC_HOP_INSTANCE_DIR TUIC_HOP_NFT_RULE_DIR TUIC_HOP_APPLY_SCRIPT
 export TUIC_HOP_SYSTEMD_TEMPLATE TUIC_HOP_SKIP_SYSTEMD TUIC_HOP_SKIP_NFT TUIC_HOP_SKIP_UFW

 err() {
     printf 'ERROR: %s\n' "$*" >&2
     return 1
 }

 warn() {
     printf 'WARN: %s\n' "$*" >&2
 }

 ui_warn() { warn "$*"; }
 ui_print() { printf '%b\n' "$*"; }
 ui_blank() { printf '\n'; }
 ui_kv() { printf '%s%*s%s\n' "$1" 18 '' "${2:-}"; }

 # 仅加载 backup.sh 的安全原语（不触发 init.sh 的运行态探测）。
 # shellcheck disable=SC1091
 . "$REPO_ROOT/src/backup.sh"

 mkdir -p "$is_conf_dir" "$is_backup_dir"

 # 模拟一个已存在的 TUIC 配置（旧端口 10443，内容标记 OLD-PORT）。
 tuic_config_file="$is_conf_dir/tuic-10443.json"
 tuic_config_name="tuic-10443"
 printf 'OLD-PORT\n' >"$tuic_config_file"

 # 1) 模拟 tuic_commit_upsert 成功 finalize：把 TUIC 配置改为新端口内容（标记 NEW-PORT）。
 init_backup_transaction change-tuic
 safe_write_file "$tuic_config_file" 'NEW-PORT'
 finalize_backup_transaction
 committed_txn_dir=${IS_LAST_BACKUP_TXN_DIR:-}
 [[ $committed_txn_dir ]] || fail 'commit must set IS_LAST_BACKUP_TXN_DIR'
 [[ -f $tuic_config_file ]] && [[ $(cat "$tuic_config_file") == 'NEW-PORT' ]] || \
     fail 'setup: TUIC config should reflect NEW-PORT after simulated commit'

 # 2) 在 source tuic.sh 前注入会失败的 tuic_apply_hop_change_action。
 tuic_apply_hop_change_action() {
     printf 'INJECTED-HOP-FAILURE\n' >&2
     return 1
 }

 # tuic.sh 定义 tuic_rollback_port_change_after_hop_failure 与 tuic_change；source 不执行顶层逻辑。
 # shellcheck disable=SC1091
 . "$REPO_ROOT/src/tuic.sh"

 # 3) 调用 helper（直接），断言 TUIC 配置回滚到 OLD-PORT 并报告残留。
 rollback_out="$TEST_ROOT/rollback.out"
 {
     tuic_rollback_port_change_after_hop_failure 10443 443 >"$rollback_out" 2>&1 || true
 }

 assert_file_content "$tuic_config_file" 'OLD-PORT' \
     'hop-failure rollback must restore TUIC config to old-port content'
 assert_contains "$rollback_out" '10443' \
     'hop-failure rollback must report old-port hop residuals'
 assert_contains "$rollback_out" 'hop 步骤失败' \
     'hop-failure rollback must surface an explicit hop-step-failure message'

 # 4) 契约：tuic_change 的 hop-failure 分支必须调用该 helper，而不是直接 return 1。
 tuic_change_body=$(sed -n '/^tuic_change()/,/^tuic_confirm_delete()/p' "$REPO_ROOT/src/tuic.sh")
 [[ $tuic_change_body == *'tuic_rollback_port_change_after_hop_failure'* ]] || \
     fail 'tuic_change must call tuic_rollback_port_change_after_hop_failure on hop failure'
 [[ $tuic_change_body == *'tuic_apply_hop_change_action "$current_port" "$tuic_port"'* ]] || \
     fail 'tuic_change must still invoke tuic_apply_hop_change_action with current/new port'

 # 5) 契约：helper 优先用 IS_LAST_BACKUP_TXN_DIR / rollback_backup_transaction_dir，保留 latest 兜底。
 helper_body=$(sed -n '/^tuic_rollback_port_change_after_hop_failure()/,/^}/p' "$REPO_ROOT/src/tuic.sh")
 [[ $helper_body == *'rollback_backup_transaction_dir "$txn_dir" --yes'* ]] || \
     fail 'helper must rollback the committed transaction dir via rollback_backup_transaction_dir'
 [[ $helper_body == *'tuic_hop_report_residuals'* ]] || \
     fail 'helper must report hop residuals'
 [[ $helper_body == *'IS_LAST_BACKUP_TXN_DIR'* ]] || \
     fail 'helper must target IS_LAST_BACKUP_TXN_DIR (set by commit finalize)'

 printf '[PASS] tuic change hop-failure rollback checks\n'
