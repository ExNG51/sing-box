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
        cat "$file" >&2
        fail "$description"
    }
}

assert_not_contains() {
    local file=$1
    local text=$2
    local description=$3
    if grep -Fq -- "$text" "$file"; then
        cat "$file" >&2
        fail "$description"
    fi
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
AUDIT_DIR="$REPO_ROOT/.audit-tmp"
mkdir -p "$AUDIT_DIR"
TEST_ROOT="$(mktemp -d "$AUDIT_DIR/mock-update-root.XXXXXX")"
UPDATE_BLOCK="$TEST_ROOT/core_update.block"
DOWNLOAD_BLOCK="$TEST_ROOT/download.block"
UNINSTALL_BLOCK="$TEST_ROOT/uninstall.block"
RISKS="$AUDIT_DIR/update-uninstall-risks.tsv"
LOG="$AUDIT_DIR/mock-update-uninstall.log"
: >"$RISKS"
: >"$LOG"

exec >>"$LOG" 2>&1

risk() {
    printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >>"$RISKS"
}

awk '/update\(\)/,/^}/ { print }' "$REPO_ROOT/src/core.sh" >"$UPDATE_BLOCK"
awk '/download\(\)/,/^}/ { print }' "$REPO_ROOT/src/download.sh" >"$DOWNLOAD_BLOCK"
awk '/uninstall\(\)/,/^}/ { print }' "$REPO_ROOT/src/core.sh" >"$UNINSTALL_BLOCK"

assert_contains "$UPDATE_BLOCK" 'resolve_core_version_policy' 'core update must use version policy resolver'
assert_contains "$UPDATE_BLOCK" 'parse_core_version_policy_args' 'core update must parse --latest/--core-version'
assert_contains "$UPDATE_BLOCK" 'begin_backup_transaction_if_needed "update-$is_update_name"' 'update must create backup transaction'
assert_contains "$DOWNLOAD_BLOCK" 'backup_path_before_write "$is_sh_dir"' 'script update must back up script directory'
assert_contains "$DOWNLOAD_BLOCK" 'safe_copy_file "$tmpdir/caddy" "$is_caddy_bin"' 'caddy update must copy binary through safe wrapper'
assert_contains "$DOWNLOAD_BLOCK" 'safe_chmod_path 0755 "$is_caddy_bin"' 'caddy update must chmod through safe wrapper'

assert_contains "$UNINSTALL_BLOCK" 'backup_standard_managed_paths' 'uninstall must back up standard managed paths'
assert_contains "$UNINSTALL_BLOCK" 'safe_remove_path' 'uninstall must remove through safe_remove_path'
assert_contains "$UNINSTALL_BLOCK" 'safe_remove_shell_aliases' 'uninstall must remove aliases through marker block helper'
assert_not_contains "$UNINSTALL_BLOCK" 'sed -i' 'uninstall must not broad sed shell aliases'
assert_not_contains "$UNINSTALL_BLOCK" 'rm -rf' 'uninstall must not directly rm -rf production paths'

rg -n '^_rm\(\)|safe_remove_path "\$@"|^_cp\(\)|safe_copy_file|safe_copy_contents|^_sed\(\)|safe_sed_inplace|^_mkdir\(\)|safe_ensure_dir' "$REPO_ROOT/src/init.sh" >"$TEST_ROOT/legacy-helper-routing.out"
assert_contains "$TEST_ROOT/legacy-helper-routing.out" 'safe_remove_path "$@"' '_rm must route to safe_remove_path'
assert_contains "$TEST_ROOT/legacy-helper-routing.out" 'safe_copy_file' '_cp must route to safe_copy_file'
assert_contains "$TEST_ROOT/legacy-helper-routing.out" 'safe_sed_inplace' '_sed must route to safe_sed_inplace'
assert_contains "$TEST_ROOT/legacy-helper-routing.out" 'safe_ensure_dir' '_mkdir must route to safe_ensure_dir'

if rg -n 'tar zxf "\$tmpfile" --strip-components 1 -C "\$is_core_dir/bin"' "$REPO_ROOT/src/download.sh" >/dev/null; then
    risk P1 src/download.sh 'download core' 'core update extracts tar directly into production bin after backing up only the expected binary'
fi
if rg -n 'tar zxf "\$is_core_ok" --strip-components 1 -C "\$is_core_dir/bin"' "$REPO_ROOT/install.sh" >/dev/null; then
    risk P1 install.sh 'execute_install' 'default install extracts core tar directly into production bin; extra archive files are not individually manifested'
fi
if rg -n '\[\[ ! -d \$is_caddy_conf \]\] && mkdir -p \$is_caddy_conf' "$REPO_ROOT/src/core.sh" >/dev/null; then
    risk P1 src/core.sh 'create caddy' 'Caddy conf directory can be created with raw mkdir -p instead of safe_ensure_dir'
fi
if rg -n 'mkdir -p \$is_caddy_dir \$is_caddy_dir/sites \$is_caddy_conf' "$REPO_ROOT/src/caddy.sh" >/dev/null; then
    risk P1 src/caddy.sh 'caddy_config new' 'Caddy production directories can be created with raw mkdir -p instead of safe_ensure_dir'
fi
if rg -n 'cat <<<.*>\$is_config_json' "$REPO_ROOT/src/dns.sh" "$REPO_ROOT/src/log.sh" >/dev/null; then
    risk P1 'src/dns.sh,src/log.sh' 'dns_set/log_set' 'config.json can be overwritten outside safe_write_file and outside a backup transaction'
fi
if rg -n 'rm -rf \$is_log_dir/\*\.log' "$REPO_ROOT/src/log.sh" >/dev/null; then
    risk P1 src/log.sh 'log_set del/none' 'log files can be removed with raw rm -rf outside safe_remove_path'
fi
if rg -n 'rm \$1' "$REPO_ROOT/src/import.sh" >/dev/null; then
    risk P1 src/import.sh 'in_conf' 'import deletes source xray/v2ray config with raw rm outside managed allowlist'
fi
if rg -n 'chmod \+x /usr/bin/jq' "$REPO_ROOT/install.sh" >/dev/null; then
    risk P1 install.sh 'execute_install' 'jq installed to /usr/bin is chmodded with raw chmod instead of safe_chmod_path and is not TEST_ROOT mappable'
fi
if rg -n '>\$is_tls_(tmp|key|cer)|rm \$is_tls_tmp' "$REPO_ROOT/src/init.sh" >/dev/null; then
    risk P1 src/init.sh 'startup TLS key generation' 'TLS key/cert files under core bin are written and removed outside backup transaction'
fi
if rg -n 'sed -i .* /etc/sysctl\.conf|>>/etc/sysctl\.conf' "$REPO_ROOT/src/bbr.sh" >/dev/null; then
    risk P2 src/bbr.sh '_open_bbr' 'BBR modifies /etc/sysctl.conf without backup transaction; outside sing-box managed-file scope'
fi
if rg -n 'tar zcvf code\.tar\.gz \./\*' "$REPO_ROOT/.github/workflows/release.yml" >/dev/null; then
    risk P2 .github/workflows/release.yml 'tar' 'release package includes every root-level path, so committed audit artifacts would be packaged unless excluded'
fi

cat "$RISKS"
printf '[PASS] mock update/uninstall path audit root: %s\n' "$TEST_ROOT"
