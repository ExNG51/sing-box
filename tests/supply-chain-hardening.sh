#!/usr/bin/env bash
set -euo pipefail

fail() {
    printf '[FAIL] %s\n' "$1" >&2
    exit 1
}

MATCH_OUTPUT="$(mktemp)"
trap 'rm -f "$MATCH_OUTPUT"' EXIT

find_matches() {
    local pattern="$1"
    shift

    if command -v rg >/dev/null 2>&1; then
        rg -n "$pattern" "$@" >"$MATCH_OUTPUT" 2>/dev/null
    else
        grep -REn "$pattern" "$@" >"$MATCH_OUTPUT" 2>/dev/null
    fi
}

assert_no_match() {
    local pattern="$1"
    local description="$2"
    if find_matches "$pattern" install.sh src; then
        cat "$MATCH_OUTPUT" >&2
        fail "$description"
    fi
}

assert_match() {
    local pattern="$1"
    local file="$2"
    local description="$3"
    find_matches "$pattern" "$file" || fail "$description"
}

shopt -s nullglob
for file in install.sh sing-box.sh src/*.sh; do
    bash -n "$file"
done

assert_no_match 'wget --no-check-certificate' 'wget must not disable TLS certificate verification by default'
assert_no_match 'mktemp -u' 'temporary paths must be created with mktemp -d or mktemp, not mktemp -u'

assert_match 'ca-certificates' install.sh 'install.sh must install CA certificates before HTTPS downloads'
assert_match 'ca-certificates' src/init.sh 'runtime dependency list must include CA certificates'

assert_match 'verify_sha256' install.sh 'install.sh must verify downloaded release assets'
assert_match 'get_github_asset_digest' install.sh 'install.sh must read GitHub release asset digest metadata'
assert_match 'verify_sha256' src/download.sh 'src/download.sh must verify downloaded release assets'
assert_match 'get_github_asset_digest' src/download.sh 'src/download.sh must read GitHub release asset digest metadata'

assert_match 'insecure_download' install.sh 'install.sh must keep insecure download behind an explicit opt-in flag'

assert_match 'run: bash tests/supply-chain-hardening.sh' .github/workflows/release.yml 'release workflow must run hardening checks before packaging'
awk '
    /run: bash tests\/supply-chain-hardening\.sh/ { check_line = NR }
    /- name: tar/ { tar_line = NR }
    END { exit !(check_line && tar_line && check_line < tar_line) }
' .github/workflows/release.yml || fail 'release workflow hardening checks must run before the tar step'

printf '[PASS] supply-chain hardening checks\n'
