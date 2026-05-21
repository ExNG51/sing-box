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

assert_match 'LISTEN[[:space:]].*:443' "$FIXTURE_DIR/ss-tcp-443-used.txt" \
    "tcp 443 fixture should contain LISTEN on :443"
assert_match 'UNCONN[[:space:]].*:443' "$FIXTURE_DIR/ss-udp-443-used.txt" \
    "udp 443 fixture should contain UNCONN on :443"
assert_match 'LISTEN[[:space:]].*:443' "$FIXTURE_DIR/ss-tcp-udp-443-used.txt" \
    "combined fixture should contain tcp 443"
assert_match 'UNCONN[[:space:]].*:443' "$FIXTURE_DIR/ss-tcp-udp-443-used.txt" \
    "combined fixture should contain udp 443"
if grep -Eq '(^|[[:space:]]):443([[:space:]]|$)' "$FIXTURE_DIR/ss-no-443-used.txt"; then
    fail "no-443 fixture unexpectedly contains :443"
fi
pass "port-detection fixtures distinguish tcp and udp samples"

assert_match 'is_port_used\(\)' "$REPO_ROOT/src/core.sh" \
    "core.sh should still define is_port_used baseline"
assert_match 'netstat -tunlp|ss -tunlp' "$REPO_ROOT/src/core.sh" \
    "is_port_used should still use mixed tcp/udp probing before Task A"
assert_match 'get_port\(\)' "$REPO_ROOT/src/core.sh" \
    "core.sh should still define get_port"
assert_match 'is_test port_used \$tmp_port' "$REPO_ROOT/src/core.sh" \
    "get_port should still depend on mixed port_used baseline"
assert_match 'is_test port_used \$REPLY' "$REPO_ROOT/src/core.sh" \
    "ask string port should still depend on mixed port_used baseline"
assert_match 'is_test port_used \$is_new_port' "$REPO_ROOT/src/core.sh" \
    "change port should still depend on mixed port_used baseline"
pass "current mixed port detection baseline is locatable"

assert_match 'allow_ufw_tcp_443\(\)' "$REPO_ROOT/src/firewall.sh" \
    "firewall.sh should expose UFW TCP 443 helper"
assert_match 'allow_firewalld_tcp_443\(\)' "$REPO_ROOT/src/firewall.sh" \
    "firewall.sh should expose firewalld TCP 443 helper"
assert_match 'warn_manual_firewall_tcp_443\(\)' "$REPO_ROOT/src/firewall.sh" \
    "firewall.sh should expose manual TCP 443 guidance"
pass "current TCP 443 firewall helpers are locatable"

if grep -Eq 'allow_ufw_udp_443|allow_firewalld_udp_443|ensure_.*udp_443' "$REPO_ROOT/src/firewall.sh"; then
    pass "UDP 443 helper already exists"
else
    pending "UDP 443 firewall helper is intentionally absent before Task A"
fi
