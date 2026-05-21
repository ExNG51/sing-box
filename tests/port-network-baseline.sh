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

assert_eq() {
    local expected=$1
    local actual=$2
    local description=$3

    [[ $actual == "$expected" ]] || fail "$description (expected: $expected, actual: $actual)"
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE_DIR="$REPO_ROOT/tests/fixtures/port-detection"

for fixture in \
    ss-tcp-443-used.txt \
    ss-udp-443-used.txt \
    ss-tcp-udp-443-used.txt \
    ss-no-443-used.txt
do
    assert_file "$FIXTURE_DIR/$fixture"
done
pass "port-detection fixtures exist"

mock_bin=$(mktemp -d "${TMPDIR:-/tmp}/sing-box-port-test.XXXXXX") || fail "failed to create temp mock bin"
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

# shellcheck source=/dev/null
source "$REPO_ROOT/src/core.sh"

assert_tcp_used() {
    local description=$1

    unset is_tcp_used_port is_udp_used_port is_used_port is_cant_test_port
    is_tcp_port_used 443 >/dev/null || fail "$description"
}

assert_tcp_free() {
    local description=$1

    unset is_tcp_used_port is_udp_used_port is_used_port is_cant_test_port
    is_tcp_port_used 443 >/dev/null && fail "$description"
}

assert_udp_used() {
    local description=$1

    unset is_tcp_used_port is_udp_used_port is_used_port is_cant_test_port
    is_udp_port_used 443 >/dev/null || fail "$description"
}

assert_udp_free() {
    local description=$1

    unset is_tcp_used_port is_udp_used_port is_used_port is_cant_test_port
    is_udp_port_used 443 >/dev/null && fail "$description"
}

assert_protocol_used() {
    local protocol=$1
    local description=$2

    unset is_tcp_used_port is_udp_used_port is_used_port is_cant_test_port
    is_listen_port_used_for_protocol "$protocol" 443 >/dev/null || fail "$description"
}

assert_protocol_free() {
    local protocol=$1
    local description=$2

    unset is_tcp_used_port is_udp_used_port is_used_port is_cant_test_port
    is_listen_port_used_for_protocol "$protocol" 443 >/dev/null && fail "$description"
}

PORT_TEST_TCP_FIXTURE="$FIXTURE_DIR/ss-tcp-443-used.txt"
PORT_TEST_UDP_FIXTURE="$FIXTURE_DIR/ss-no-443-used.txt"
export PORT_TEST_TCP_FIXTURE PORT_TEST_UDP_FIXTURE
assert_tcp_used "tcp 443 fixture should make tcp detector true"
assert_udp_free "tcp 443 fixture should make udp detector false"
assert_protocol_used AnyTLS "tcp 443 fixture should block AnyTLS TCP 443"
assert_protocol_free TUIC "tcp 443 fixture should not block TUIC UDP 443"
pass "tcp-only fixture separates tcp used from udp free"

PORT_TEST_TCP_FIXTURE="$FIXTURE_DIR/ss-no-443-used.txt"
PORT_TEST_UDP_FIXTURE="$FIXTURE_DIR/ss-udp-443-used.txt"
export PORT_TEST_TCP_FIXTURE PORT_TEST_UDP_FIXTURE
assert_tcp_free "udp 443 fixture should make tcp detector false"
assert_udp_used "udp 443 fixture should make udp detector true"
assert_protocol_free AnyTLS "udp 443 fixture should not block AnyTLS TCP 443"
assert_protocol_used TUIC "udp 443 fixture should block TUIC UDP 443"
pass "udp-only fixture separates udp used from tcp free"

PORT_TEST_TCP_FIXTURE="$FIXTURE_DIR/ss-tcp-udp-443-used.txt"
PORT_TEST_UDP_FIXTURE="$FIXTURE_DIR/ss-tcp-udp-443-used.txt"
export PORT_TEST_TCP_FIXTURE PORT_TEST_UDP_FIXTURE
assert_tcp_used "combined fixture should make tcp detector true"
assert_udp_used "combined fixture should make udp detector true"
pass "combined fixture reports tcp and udp 443 used"

PORT_TEST_TCP_FIXTURE="$FIXTURE_DIR/ss-no-443-used.txt"
PORT_TEST_UDP_FIXTURE="$FIXTURE_DIR/ss-no-443-used.txt"
export PORT_TEST_TCP_FIXTURE PORT_TEST_UDP_FIXTURE
assert_tcp_free "no-443 fixture should make tcp detector false"
assert_udp_free "no-443 fixture should make udp detector false"
pass "no-443 fixture reports tcp and udp 443 free"

assert_eq tcp "$(get_inbound_listen_network AnyTLS)" "AnyTLS should map to tcp"
assert_eq udp "$(get_inbound_listen_network TUIC)" "TUIC should map to udp"
assert_eq udp "$(get_inbound_listen_network Hysteria2)" "Hysteria2 should map to udp"
assert_eq any "$(get_inbound_listen_network Shadowsocks)" "Shadowsocks should map to any"
pass "protocol listen network mappings are protocol-aware"

assert_match 'is_tcp_port_used\(\)' "$REPO_ROOT/src/core.sh" \
    "core.sh should expose TCP port detector"
assert_match 'is_udp_port_used\(\)' "$REPO_ROOT/src/core.sh" \
    "core.sh should expose UDP port detector"
assert_match 'is_any_port_used\(\)' "$REPO_ROOT/src/core.sh" \
    "core.sh should preserve conservative any-port detector"
assert_match 'is_listen_port_used_for_protocol\(\)' "$REPO_ROOT/src/core.sh" \
    "core.sh should expose protocol-aware port detector"
assert_match 'ss -ltnH' "$REPO_ROOT/src/core.sh" \
    "TCP detector should prefer ss -ltnH"
assert_match 'ss -lunH' "$REPO_ROOT/src/core.sh" \
    "UDP detector should prefer ss -lunH"
pass "protocol-aware port detection helpers are locatable"

assert_match 'assert_anytls_acme_port_available\(\)' "$REPO_ROOT/src/core.sh" \
    "core.sh should define AnyTLS ACME port preflight"
assert_match 'is_tcp_port_used 443' "$REPO_ROOT/src/core.sh" \
    "AnyTLS ACME port preflight should check TCP 443 only"
assert_match 'preflight_udp_443_if_needed\(\)' "$REPO_ROOT/src/core.sh" \
    "core.sh should define UDP 443 preflight"
assert_match 'ensure_udp_443_firewall' "$REPO_ROOT/src/core.sh" \
    "UDP 443 preflight should call firewall helper"
pass "AnyTLS ACME and UDP 443 preflight call sites are locatable"

assert_match 'allow_ufw_tcp_443\(\)' "$REPO_ROOT/src/firewall.sh" \
    "firewall.sh should keep UFW TCP 443 helper"
assert_match 'allow_firewalld_tcp_443\(\)' "$REPO_ROOT/src/firewall.sh" \
    "firewall.sh should keep firewalld TCP 443 helper"
assert_match 'warn_manual_firewall_tcp_443\(\)' "$REPO_ROOT/src/firewall.sh" \
    "firewall.sh should keep manual TCP 443 guidance"
pass "TCP 443 firewall helpers remain locatable"

assert_match 'allow_ufw_udp_443\(\)' "$REPO_ROOT/src/firewall.sh" \
    "firewall.sh should expose UFW UDP 443 helper"
assert_match 'allow_firewalld_udp_443\(\)' "$REPO_ROOT/src/firewall.sh" \
    "firewall.sh should expose firewalld UDP 443 helper"
assert_match 'warn_manual_firewall_udp_443\(\)' "$REPO_ROOT/src/firewall.sh" \
    "firewall.sh should expose manual UDP 443 guidance"
assert_match 'ensure_udp_443_firewall\(\)' "$REPO_ROOT/src/firewall.sh" \
    "firewall.sh should expose UDP 443 firewall preflight"
assert_match 'warn_udp_443_external_firewall\(\)' "$REPO_ROOT/src/firewall.sh" \
    "firewall.sh should expose UDP 443 cloud security group warning"
pass "UDP 443 firewall helpers are locatable"
