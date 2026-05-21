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

assert_not_match() {
    local pattern=$1
    local file=$2
    local description=$3

    if command -v rg >/dev/null 2>&1; then
        rg -n "$pattern" "$file" >/dev/null && fail "$description"
    else
        grep -En "$pattern" "$file" >/dev/null && fail "$description"
    fi
}

assert_eq() {
    local expected=$1
    local actual=$2
    local description=$3

    [[ $actual == "$expected" ]] || fail "$description (expected: $expected, actual: $actual)"
}

assert_json_string_expr() {
    local json=$1
    local expr=$2
    local description=$3

    jq -e "$expr" <<<"$json" >/dev/null || fail "$description"
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE_DIR="$REPO_ROOT/tests/fixtures/port-detection"
TUIC_FIXTURE_DIR="$REPO_ROOT/tests/fixtures/tuic"
mock_bin=$(mktemp -d "${TMPDIR:-/tmp}/sing-box-tuic-test.XXXXXX") || fail "failed to create temp mock bin"
trap 'rm -rf "$mock_bin"' EXIT

cat >"$mock_bin/ss" <<'MOCK_SS'
#!/usr/bin/env bash
case "$1" in
-ltnH) cat "$PORT_TEST_TCP_FIXTURE" ;;
-lunH) cat "$PORT_TEST_UDP_FIXTURE" ;;
*) exit 1 ;;
esac
MOCK_SS
chmod +x "$mock_bin/ss"
PATH="$mock_bin:$PATH"

assert_file "$REPO_ROOT/src/tuic.sh"

# shellcheck source=/dev/null
source "$REPO_ROOT/src/core.sh"
# shellcheck source=/dev/null
source "$REPO_ROOT/src/cert.sh"
# shellcheck source=/dev/null
source "$REPO_ROOT/src/tuic.sh"

is_core_dir=/etc/sing-box
is_conf_dir=/etc/sing-box/conf
is_config_json=/etc/sing-box/config.json
is_gen=1
is_core_ver=1.14.0

tuic_reset_state
tuic_parse_add_args --port 10443 --uuid auto --password auto --insecure
tuic_prepare_add_state
[[ $tuic_uuid ]] || fail "auto uuid should be generated"
[[ $tuic_password ]] || fail "auto password should be generated"
[[ $tuic_uuid != "$tuic_password" ]] || fail "new TUIC add flow should not default password to uuid"
assert_eq bbr "$tuic_cc" "TUIC congestion control should default to bbr"
pass "TUIC add state generates independent credentials and bbr default"

tuic_json=$(tuic_render_inbound_json)
assert_json_string_expr "$tuic_json" \
    '.inbounds[0].type == "tuic" and .inbounds[0].listen_port == 10443 and .inbounds[0].congestion_control == "bbr" and .inbounds[0].tls.alpn[0] == "h3" and .inbounds[0].tls.certificate_path == "/etc/sing-box/bin/tls.cer"' \
    "TUIC insecure render should include UDP port, bbr, h3, and self-signed cert"
tuic_url=$(tuic_render_client_url "$tuic_json")
[[ $tuic_url == *"allow_insecure=1"* ]] || fail "TUIC insecure URL should include allow_insecure=1"
pass "TUIC insecure render and URL carry allow_insecure"

tuic_reset_state
tuic_parse_add_args --port 443 --uuid 11111111-1111-1111-1111-111111111111 --password pass123 --domain example.com --tls acme
tuic_prepare_add_state
tuic_json=$(tuic_render_inbound_json)
assert_json_string_expr "$tuic_json" \
    '.inbounds[0].tls.server_name == "example.com" and .inbounds[0].tls.alpn[0] == "h3" and .inbounds[0].tls.certificate_provider == "acme-example.com" and .certificate_providers[0].tag == "acme-example.com"' \
    "TUIC ACME provider render should include server_name, h3, provider, and root provider"
tuic_url=$(tuic_render_client_url "$tuic_json")
[[ $tuic_url != *"allow_insecure=1"* ]] || fail "TUIC domain cert URL should not include allow_insecure=1"
[[ $tuic_url == "tuic://11111111-1111-1111-1111-111111111111:pass123@example.com:443?alpn=h3&congestion_control=bbr#sing-box-tuic-example.com" ]] || fail "TUIC domain URL should use domain endpoint without insecure flag"
pass "TUIC domain provider render and URL omit allow_insecure"

tuic_reset_state
tuic_parse_add_args --port 443 --uuid 11111111-1111-1111-1111-111111111111 --password pass123 --domain example.com --cert-file /path/fullchain.cer --key-file /path/private.key
tuic_prepare_add_state
tuic_json=$(tuic_render_inbound_json)
assert_json_string_expr "$tuic_json" \
    '.inbounds[0].tls.server_name == "example.com" and .inbounds[0].tls.alpn[0] == "h3" and .inbounds[0].tls.certificate_path == "/path/fullchain.cer" and .inbounds[0].tls.key_path == "/path/private.key"' \
    "TUIC file cert render should include server_name, h3, certificate_path, and key_path"
pass "TUIC file certificate render includes protocol TLS fields"

tuic_reset_state
tuic_read_config "$TUIC_FIXTURE_DIR/tuic-ip-insecure.json"
tuic_parse_change_args --domain example.com --tls acme
tuic_prepare_change_state
tuic_json=$(tuic_render_inbound_json)
assert_json_string_expr "$tuic_json" \
    '.inbounds[0].tls.certificate_provider == "acme-example.com" and (.inbounds[0].tls.certificate_path | not) and (.inbounds[0].tls.key_path | not)' \
    "TUIC migrate/change to ACME should not retain old self-signed certificate paths"
pass "TUIC migration to ACME clears insecure file certificate state"

PORT_TEST_TCP_FIXTURE="$FIXTURE_DIR/ss-tcp-443-used.txt"
PORT_TEST_UDP_FIXTURE="$FIXTURE_DIR/ss-no-443-used.txt"
export PORT_TEST_TCP_FIXTURE PORT_TEST_UDP_FIXTURE
reset_port_detection_cache
tuic_validate_port_available 443 "" || fail "TUIC UDP/443 should not be blocked by TCP/443 fixture"

PORT_TEST_TCP_FIXTURE="$FIXTURE_DIR/ss-no-443-used.txt"
PORT_TEST_UDP_FIXTURE="$FIXTURE_DIR/ss-udp-443-used.txt"
export PORT_TEST_TCP_FIXTURE PORT_TEST_UDP_FIXTURE
reset_port_detection_cache
tuic_validate_port_available 443 "" >/dev/null 2>&1 && fail "TUIC UDP/443 should be blocked by UDP/443 fixture"
pass "TUIC port validation is protocol-aware for UDP/443"

audit_output=$(tuic_audit_json "$TUIC_FIXTURE_DIR")
assert_json_string_expr "$audit_output" \
    '.total == 4 and .insecure >= 1 and .domain_cert >= 2 and .password_equals_uuid >= 1 and .udp_443 >= 2 and .port_hopping == "not integrated"' \
    "TUIC audit JSON should count fixture modes and keep port-hopping not integrated"
pass "TUIC audit counts lifecycle fixture states without modifying configs"

assert_match 'load tuic\.sh' "$REPO_ROOT/src/core.sh" \
    "core.sh should load TUIC module for structured namespace"
assert_match 'tuic_main' "$REPO_ROOT/src/core.sh" \
    "core.sh should dispatch sing-box tuic namespace"
assert_match 'Port-Hopping lifecycle integration is reserved for Task D' "$REPO_ROOT/src/tuic.sh" \
    "TUIC module should keep Port-Hopping as Task D notice"
assert_not_match 'tuic-port-hopping@|NFT_TABLE_NAME|nft add|nft -f|ufw allow .*:.*udp' "$REPO_ROOT/src/tuic.sh" \
    "TUIC module should not manage Port-Hopping production objects"
pass "TUIC namespace and Task D boundary are locatable"
