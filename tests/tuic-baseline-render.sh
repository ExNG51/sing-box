#!/usr/bin/env bash
set -o pipefail

fail() {
    printf '[FAIL] %s\n' "$1" >&2
    exit 1
}

pass() {
    printf '[PASS] %s\n' "$1"
}

pending() {
    printf '[PENDING] %s\n' "$1"
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
TUIC_FIXTURE_DIR="$REPO_ROOT/tests/fixtures/tuic"
HOP_FIXTURE_DIR="$REPO_ROOT/tests/fixtures/tuic-hop"

for fixture in \
    tuic-ip-insecure.json \
    tuic-domain-provider.json \
    tuic-domain-file-cert.json \
    tuic-bbr-default.json
do
    assert_file "$TUIC_FIXTURE_DIR/$fixture"
    assert_json "$TUIC_FIXTURE_DIR/$fixture"
    assert_json_expr "$TUIC_FIXTURE_DIR/$fixture" \
        '.inbounds[0].type == "tuic" and .inbounds[0].congestion_control and .inbounds[0].tls.enabled == true' \
        "TUIC fixture should include type, congestion_control, and TLS: $fixture"
done
pass "TUIC fixtures exist and contain required fields"

assert_json_expr "$TUIC_FIXTURE_DIR/tuic-ip-insecure.json" \
    '.inbounds[0].tls.certificate_path == "/etc/sing-box/bin/tls.cer" and .inbounds[0].tls.alpn[0] == "h3"' \
    "current IP/insecure TUIC fixture should reflect self-signed h3 mode"
assert_json_expr "$TUIC_FIXTURE_DIR/tuic-domain-provider.json" \
    '.inbounds[0].tls.certificate_provider == "acme-example.com" and .certificate_providers[0].type == "acme"' \
    "domain provider TUIC fixture should model target provider certificate"
assert_json_expr "$TUIC_FIXTURE_DIR/tuic-bbr-default.json" \
    '.inbounds[0].congestion_control == "bbr"' \
    "TUIC BBR fixture should pin bbr default"
pass "TUIC fixture profiles contain expected baseline and target fields"

for fixture in \
    hop-instance-443.env \
    hop-instance-443.nft \
    systemd-status-active.txt \
    ufw-status-active.txt
do
    assert_file "$HOP_FIXTURE_DIR/$fixture"
done
assert_match 'REAL_PORT="443"' "$HOP_FIXTURE_DIR/hop-instance-443.env" \
    "hop env fixture should include REAL_PORT"
assert_match 'RANGE_START="10443"' "$HOP_FIXTURE_DIR/hop-instance-443.env" \
    "hop env fixture should include RANGE_START"
assert_match 'udp dport 10443-10542 redirect to :443' "$HOP_FIXTURE_DIR/hop-instance-443.nft" \
    "hop nft fixture should include redirect rule"
assert_match 'Active: active' "$HOP_FIXTURE_DIR/systemd-status-active.txt" \
    "systemd fixture should include active state"
assert_match '10443:10542/udp' "$HOP_FIXTURE_DIR/ufw-status-active.txt" \
    "ufw fixture should include hopping range"
pass "TUIC port-hopping fixtures contain expected fields"

assert_match 'tuic\)' "$REPO_ROOT/src/core.sh" \
    "core.sh should still contain the TUIC protocol branch"
assert_match 'congestion_control:\\"bbr\\"|congestion_control:"bbr"' "$REPO_ROOT/src/core.sh" \
    "core.sh should still render TUIC bbr baseline"
assert_match 'alpn:\["h3"\]' "$REPO_ROOT/src/core.sh" \
    "core.sh should still render h3 ALPN baseline"
assert_match 'allow_insecure=1' "$REPO_ROOT/src/core.sh" \
    "core.sh should still output TUIC allow_insecure URL baseline"
pass "current TUIC render and URL baseline is locatable"

if grep -Eq 'tuic_port_hopping|port-hopping|NFT_TABLE_NAME' "$REPO_ROOT/src/core.sh" "$REPO_ROOT/src/firewall.sh"; then
    pass "TUIC port-hopping production integration already exists"
else
    pending "TUIC port-hopping production integration is intentionally absent before Task D"
fi
