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

assert_json() {
    local file=$1
    command -v jq >/dev/null 2>&1 || fail "jq is required for JSON fixture validation"
    jq empty "$file" >/dev/null || fail "invalid JSON: $file"
}

assert_json_expr() {
    local file=$1
    local expr=$2
    local description=$3

    jq -e "$expr" "$file" >/dev/null || fail "$description"
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE_DIR="$REPO_ROOT/tests/fixtures/cert"

assert_file "$FIXTURE_DIR/README.md"
assert_match '后续目标状态 fixture' "$FIXTURE_DIR/README.md" \
    "cert fixture README should mark future-state fixtures"

for fixture in \
    no-certificate.json \
    legacy-anytls-acme.json \
    provider-acme.json \
    file-cert-tuic.json \
    self-signed-tuic.json
do
    assert_file "$FIXTURE_DIR/$fixture"
    assert_json "$FIXTURE_DIR/$fixture"
done
pass "certificate fixtures exist and are valid JSON"

assert_json_expr "$FIXTURE_DIR/legacy-anytls-acme.json" \
    '.inbounds[0].tls.acme.domain[0] == "example.com"' \
    "legacy AnyTLS fixture should use tls.acme"
assert_json_expr "$FIXTURE_DIR/provider-acme.json" \
    '.inbounds[0].tls.certificate_provider == "acme-example.com" and .certificate_providers[0].type == "acme"' \
    "provider ACME fixture should use root certificate_providers"
assert_json_expr "$FIXTURE_DIR/file-cert-tuic.json" \
    '.inbounds[0].type == "tuic" and .inbounds[0].tls.certificate_path and .inbounds[0].tls.key_path' \
    "file certificate TUIC fixture should include certificate and key paths"
assert_json_expr "$FIXTURE_DIR/self-signed-tuic.json" \
    '.inbounds[0].type == "tuic" and .inbounds[0].tls.certificate_path == "/etc/sing-box/bin/tls.cer"' \
    "self-signed TUIC fixture should reflect current generated certificate path"
pass "certificate fixture profiles contain expected key fields"

assert_match 'assert_core_acme_capability\(\)' "$REPO_ROOT/src/core.sh" \
    "AnyTLS ACME capability check should be locatable"
assert_match 'with_acme' "$REPO_ROOT/src/core.sh" \
    "AnyTLS ACME should still check with_acme"
assert_match 'assert_anytls_acme_domain_dns\(\)' "$REPO_ROOT/src/core.sh" \
    "AnyTLS ACME DNS check should be locatable"
assert_match 'assert_anytls_acme_port_available\(\)' "$REPO_ROOT/src/core.sh" \
    "AnyTLS ACME TCP 443 check should be locatable"
assert_match 'check_pending_server_config\(\)' "$REPO_ROOT/src/core.sh" \
    "AnyTLS ACME temporary sing-box check should be locatable"
assert_match 'rollback_or_remove_failed_anytls_config\(\)' "$REPO_ROOT/src/core.sh" \
    "AnyTLS ACME rollback path should be locatable"
assert_match 'certificate_provider' "$REPO_ROOT/src/core.sh" \
    "sing-box 1.14+ certificate_provider path should be locatable"
assert_match 'tls:\{enabled:true,acme:' "$REPO_ROOT/src/core.sh" \
    "legacy tls.acme path should be locatable"
pass "current AnyTLS ACME baseline is locatable"
