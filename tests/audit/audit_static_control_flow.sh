#!/usr/bin/env bash
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
AUDIT_DIR="$REPO_ROOT/.audit-tmp"
LOG="$AUDIT_DIR/static-control-flow.log"
SNAPSHOT="$AUDIT_DIR/repository-snapshot.txt"
DANGEROUS_RAW="$AUDIT_DIR/dangerous-commands.raw"
DIRECT_WRITES_RAW="$AUDIT_DIR/direct-writes.raw"

mkdir -p "$AUDIT_DIR"
: >"$LOG"
: >"$DANGEROUS_RAW"
: >"$DIRECT_WRITES_RAW"

fail_count=0

log() {
    printf '%s\n' "$*" | tee -a "$LOG" >/dev/null
}

check() {
    local description=$1
    shift

    log "== $description"
    "$@" >>"$LOG" 2>&1
    local status=$?
    log "status=$status"
    if [[ $status -ne 0 ]]; then
        fail_count=$((fail_count + 1))
    fi
    return "$status"
}

assert_grep() {
    local pattern=$1
    shift
    grep -RInE -- "$pattern" "$@" >>"$LOG" 2>&1
}

assert_no_grep() {
    local pattern=$1
    shift
    if grep -RInE -- "$pattern" "$@" >>"$LOG" 2>&1; then
        return 1
    fi
    return 0
}

workflow_check_before_tar() {
    local pattern=$1
    awk -v pattern="$pattern" '
        $0 ~ pattern { check_line = NR }
        /- name: tar/ { tar_line = NR }
        END { exit !(check_line && tar_line && check_line < tar_line) }
    ' "$REPO_ROOT/.github/workflows/release.yml"
}

version_policy_simulation() {
    local tmp_audit_root
    tmp_audit_root="$(mktemp -d "$AUDIT_DIR/version-policy.XXXXXX")" || return 1
    (
        err() {
            printf 'ERROR: %s\n' "$*" >&2
            return 1
        }
        get_latest_version() {
            latest_ver=v9.9.9
            printf 'latest-called\n' >"$tmp_audit_root/latest-called"
        }

        # shellcheck disable=SC1091
        . "$REPO_ROOT/src/version.sh"

        default_selected="$(resolve_core_version_policy "" false 2>"$tmp_audit_root/default.err")" || exit 1
        latest_selected="$(resolve_core_version_policy "" true 2>"$tmp_audit_root/latest.err")" || exit 1
        explicit_selected="$(resolve_core_version_policy "1.13.8" false 2>"$tmp_audit_root/explicit.err")" || exit 1

        printf 'default=%s\n' "$default_selected"
        printf 'latest=%s\n' "$latest_selected"
        printf 'explicit=%s\n' "$explicit_selected"

        [[ $default_selected == "$DEFAULT_SING_BOX_STABLE_VERSION" ]] || exit 2
        [[ ! -e $tmp_audit_root/default-called ]] || exit 3
        [[ $latest_selected == v9.9.9 ]] || exit 4
        [[ -e $tmp_audit_root/latest-called ]] || exit 5
        [[ $explicit_selected == v1.13.8 ]] || exit 6
        resolve_core_version_policy "v1.13.8" true >"$tmp_audit_root/conflict.out" 2>&1 && exit 7
        grep -Fq 'Cannot use --latest and --core-version at the same time.' "$tmp_audit_root/conflict.out" || exit 8
    )
    local sim_rc=$?
    rm -rf "$tmp_audit_root"
    return $sim_rc
}

{
    printf 'toplevel=%s\n' "$(git -C "$REPO_ROOT" rev-parse --show-toplevel)"
    printf 'branch=%s\n' "$(git -C "$REPO_ROOT" branch --show-current)"
    printf 'head=%s\n' "$(git -C "$REPO_ROOT" rev-parse HEAD)"
    printf 'working_tree_short=\n'
    git -C "$REPO_ROOT" status --short
    printf 'latest_20_commits=\n'
    git -C "$REPO_ROOT" log --oneline --decorate --max-count=20
} >"$SNAPSHOT" 2>&1

cd "$REPO_ROOT" || exit 1
shopt -s nullglob

for shell_file in install.sh sing-box.sh src/*.sh tests/*.sh tests/audit/*.sh; do
    [[ -f $shell_file ]] || continue
    check "bash -n $shell_file" bash -n "$shell_file" || true
done

check "no default add reality command" assert_no_grep '^[[:space:]]*(sb|sing-box)?[[:space:]]*add[[:space:]]+reality([[:space:]]|$)' install.sh src || true
check "no install/src add reality aliases in default flow" assert_no_grep 'add[[:space:]]+(reality|VLESS-REALITY|vless-reality)' install.sh src || true
check "manual reality support remains" assert_grep 'VLESS-REALITY|reality' src/core.sh || true
check "manual AnyTLS support remains" assert_grep 'AnyTLS|anytls' src/core.sh || true
check "manual TUIC support remains" assert_grep 'TUIC|tuic' src/core.sh || true
check "install and README no-auto-protocol text" assert_grep 'No proxy protocol has been created automatically|未自动创建任何代理协议|no proxy protocol is created automatically|不会自动创建任何代理协议' install.sh README.md || true
check "workflow no-auto test before tar" workflow_check_before_tar 'tests/install-no-auto-reality\.sh' || true

check "no direct wget TLS bypass by default" assert_no_grep 'wget[[:space:]].*--no-check-certificate' install.sh src || true
grep -RInE -- '--no-check-certificate' install.sh src >>"$LOG" 2>&1 || true
check "insecure opt-in exists" assert_grep 'insecure_download|SING_BOX_INSECURE_DOWNLOAD|--insecure-download' install.sh src || true
check "HTTPS-only verifier exists" assert_grep 'verify_https_url|https://\*\)|拒绝非 HTTPS' install.sh src/download.sh || true
check "SHA256 verifier exists" assert_grep 'verify_sha256|get_github_asset_digest|get_release_checksum_sha256' install.sh src/download.sh || true
check "CA dependency exists" assert_grep 'ca-certificates' install.sh src/init.sh || true
check "no mktemp -u in executable scripts" assert_no_grep 'mktemp[[:space:]]+-u' install.sh src || true
grep -RInE -- 'mktemp[[:space:]]+-u' install.sh src tests >>"$LOG" 2>&1 || true
check "workflow supply-chain test before tar" workflow_check_before_tar 'tests/supply-chain-hardening\.sh' || true

check "default stable pin exists" assert_grep 'DEFAULT_SING_BOX_STABLE_VERSION' src/version.sh install.sh src/download.sh || true
check "latest must be explicit" assert_grep 'IS_USE_LATEST_VERSION|--latest|Using latest sing-box release' src/version.sh install.sh src/download.sh src/help.sh || true
check "explicit core version support exists" assert_grep 'IS_USER_CORE_VERSION_SPECIFIED|--core-version|-v' src/version.sh install.sh src/core.sh src/help.sh || true
check "latest and core-version conflict exists" assert_grep 'Cannot use --latest and --core-version at the same time' src/version.sh install.sh tests/version-pin.sh || true
check "version policy function simulation" version_policy_simulation || true

grep -RInE -- '\brm[[:space:]]+-(rf|fr|f|r)\b|cp[[:space:]]+-(rf|fr|f|a|af)\b|sed[[:space:]]+-i\b|mkdir[[:space:]]+-p\b|ln[[:space:]]+-s[f]?' install.sh src tests >"$DANGEROUS_RAW" 2>&1 || true
grep -RInE -- '(^|[^#])\b(cat|printf|echo)\b.*>|>\s*\$|>\s*/|>>\s*\$|>>\s*/|\brm\b|\bcp\b|\bmv\b|\bsed -i\b|\bmkdir -p\b|\bln -sf\b|\bchmod\b' install.sh src tests .github/workflows/release.yml >"$DIRECT_WRITES_RAW" 2>&1 || true

check "existing no-auto-reality test" bash tests/install-no-auto-reality.sh || true
check "existing supply-chain hardening test" bash tests/supply-chain-hardening.sh || true
check "existing version pin test" bash tests/version-pin.sh || true

if [[ $fail_count -gt 0 ]]; then
    log "AUDIT_STATIC_RESULT=FAIL failures=$fail_count"
    exit 1
fi

log "AUDIT_STATIC_RESULT=PASS"
printf '[PASS] static control-flow audit\n'
