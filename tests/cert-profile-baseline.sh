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

assert_json_string_expr() {
    local json=$1
    local expr=$2
    local description=$3

    jq -e "$expr" <<<"$json" >/dev/null || fail "$description"
}

assert_eq() {
    local expected=$1
    local actual=$2
    local description=$3

    [[ $actual == "$expected" ]] || fail "$description (expected: $expected, actual: $actual)"
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

# shellcheck source=/dev/null
source "$REPO_ROOT/src/core.sh"
# shellcheck source=/dev/null
source "$REPO_ROOT/src/cert.sh"

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

assert_eq legacy-acme "$(cert_detect_profile_in_json example.com <"$FIXTURE_DIR/legacy-anytls-acme.json")" \
    "legacy AnyTLS ACME fixture should be detected as legacy-acme"
assert_eq acme-provider "$(cert_detect_profile_in_json example.com <"$FIXTURE_DIR/provider-acme.json")" \
    "provider ACME fixture should be detected as acme-provider"
assert_eq file-cert "$(cert_detect_profile_in_json example.com <"$FIXTURE_DIR/file-cert-tuic.json")" \
    "file certificate fixture should be detected as file-cert"
assert_eq self-signed-insecure "$(cert_detect_profile_in_json example.com <"$FIXTURE_DIR/self-signed-tuic.json")" \
    "self-signed TUIC fixture should be detected as self-signed-insecure"
assert_eq missing "$(cert_detect_profile_in_json example.com <"$FIXTURE_DIR/no-certificate.json")" \
    "missing certificate fixture should be detected as missing"
pass "certificate module detects all fixture certificate profiles"

tmp_cert_root=$(mktemp -d "${TMPDIR:-/tmp}/sing-box-cert-test.XXXXXX") || fail "failed to create temp cert root"
trap 'rm -rf "$tmp_cert_root"' EXIT
mkdir -p "$tmp_cert_root/conf" || fail "failed to create temp conf dir"
cp "$FIXTURE_DIR/no-certificate.json" "$tmp_cert_root/config.json" || fail "failed to copy temp config"
cp "$FIXTURE_DIR/provider-acme.json" "$tmp_cert_root/conf/provider-acme.json" || fail "failed to copy temp provider config"
is_config_json="$tmp_cert_root/config.json"
is_conf_dir="$tmp_cert_root/conf"
assert_eq acme-provider "$(cert_detect_profile_for_domain example.com)" \
    "cert_detect_profile_for_domain should scan config.json and conf/*.json"
pass "certificate module scans config.json and conf/*.json"

is_core_dir=/etc/sing-box
legacy_tls=$(cert_render_tls_json legacy-acme example.com /etc/sing-box/acme)
legacy_render=$(jq "{inbounds:[{type:\"anytls\",$legacy_tls}]}" <<<'{}')
assert_json_string_expr "$legacy_render" \
    '.inbounds[0].tls.acme.domain[0] == "example.com" and .inbounds[0].tls.acme.data_directory == "/etc/sing-box/acme"' \
    "legacy AnyTLS render should keep tls.acme domain and data_directory"

provider_tls=$(cert_render_tls_json acme-provider example.com /etc/sing-box/acme)
provider_root=$(cert_render_root_extra_json acme-provider example.com /etc/sing-box/acme)
provider_render=$(jq "{inbounds:[{type:\"anytls\",$provider_tls}]$provider_root}" <<<'{}')
assert_json_string_expr "$provider_render" \
    '.inbounds[0].tls.certificate_provider == "acme-example.com" and .certificate_providers[0].tag == "acme-example.com" and .certificate_providers[0].domain[0] == "example.com"' \
    "provider AnyTLS render should keep certificate_provider and root certificate_providers"

file_tls=$(cert_render_tls_json file-cert example.com /etc/sing-box/cert/example.com.cer /etc/sing-box/cert/example.com.key)
file_render=$(jq "{inbounds:[{type:\"tuic\",$file_tls}]}" <<<'{}')
assert_json_string_expr "$file_render" \
    '.inbounds[0].tls.certificate_path == "/etc/sing-box/cert/example.com.cer" and .inbounds[0].tls.key_path == "/etc/sing-box/cert/example.com.key"' \
    "file cert render should include certificate_path and key_path"
pass "certificate module renders AnyTLS ACME and file certificate fragments"

assert_match 'assert_core_acme_capability\(\)' "$REPO_ROOT/src/core.sh" \
    "AnyTLS ACME capability check should be locatable"
assert_match 'with_acme' "$REPO_ROOT/src/cert.sh" \
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
assert_match 'load cert\.sh' "$REPO_ROOT/src/core.sh" \
    "AnyTLS ACME should load shared certificate helpers"
assert_match 'cert_preflight_acme_domain' "$REPO_ROOT/src/core.sh" \
    "AnyTLS ACME preflight should call shared certificate helper"
assert_match 'cert_render_tls_json' "$REPO_ROOT/src/core.sh" \
    "AnyTLS ACME TLS rendering should call shared certificate helper"
assert_match 'cert_render_root_extra_json' "$REPO_ROOT/src/core.sh" \
    "AnyTLS ACME root rendering should call shared certificate helper"
assert_match 'cert_acme_mode_for_core' "$REPO_ROOT/src/core.sh" \
    "AnyTLS ACME rendering should keep core-version provider/legacy selection"
pass "current AnyTLS ACME baseline is locatable"
