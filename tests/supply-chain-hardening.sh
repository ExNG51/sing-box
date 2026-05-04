#!/usr/bin/env bash
set -euo pipefail

fail() {
    printf '[FAIL] %s\n' "$1" >&2
    exit 1
}

RG_OUTPUT="$(mktemp)"
trap 'rm -f "$RG_OUTPUT"' EXIT

assert_no_match() {
    local pattern="$1"
    local description="$2"
    if rg -n "$pattern" install.sh src >"$RG_OUTPUT" 2>/dev/null; then
        cat "$RG_OUTPUT" >&2
        fail "$description"
    fi
}

assert_match() {
    local pattern="$1"
    local file="$2"
    local description="$3"
    rg -n "$pattern" "$file" >/dev/null || fail "$description"
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

printf '[PASS] supply-chain hardening checks\n'
