#!/usr/bin/env bash
set -o pipefail

fail() {
    printf '[FAIL] %s\n' "$1" >&2
    exit 1
}

pass() {
    printf '[PASS] %s\n' "$1"
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

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TUIC_FILE="$REPO_ROOT/src/tuic.sh"

assert_match '^tuic_generate_available_udp_port\(\)' "$TUIC_FILE" \
    "tuic_generate_available_udp_port should exist"
assert_match '^tuic_suggest_listen_port\(\)' "$TUIC_FILE" \
    "tuic_suggest_listen_port should exist"
assert_match '^tuic_describe_suggested_port\(\)' "$TUIC_FILE" \
    "tuic_describe_suggested_port should exist"
assert_match 'is_listen_port_used_for_protocol TUIC "\$candidate"' "$TUIC_FILE" \
    "random TUIC port generation should use protocol-aware UDP detection"
assert_match 'is_listen_port_used_for_protocol TUIC "\$preferred_port"' "$TUIC_FILE" \
    "TUIC suggestion should check UDP/443 with protocol-aware detection"
assert_match 'is_listen_port_used_for_protocol TUIC "\$fallback_port"' "$TUIC_FILE" \
    "TUIC suggestion should check UDP/10443 with protocol-aware detection"
assert_match 'suggested_port=\$\(tuic_suggest_listen_port\)' "$TUIC_FILE" \
    "tuic_menu_add_config should call tuic_suggest_listen_port"
assert_not_match '默认 10443，回车使用默认值' "$TUIC_FILE" \
    "TUIC add menu should no longer hard-code default 10443 prompt"
assert_match '建议 TUIC UDP 监听端口' "$TUIC_FILE" \
    "TUIC add menu should show the suggested UDP port"
assert_match '回车使用建议值' "$TUIC_FILE" \
    "TUIC add menu prompt should explain Enter uses the suggestion"
pass "TUIC menu suggestion static checks"

# shellcheck source=/dev/null
source "$TUIC_FILE"

is_listen_port_used_for_protocol() {
    local protocol=$1
    local port=$2

    [[ $protocol == TUIC ]] || return 1
    case "$MOCK_SCENARIO:$port" in
    all-free:*) return 1 ;;
    tcp443-used-only:443) return 1 ;;
    udp443-used:443) return 0 ;;
    udp443-used:10443) return 1 ;;
    udp443-and-10443-used:443) return 0 ;;
    udp443-and-10443-used:10443) return 0 ;;
    udp443-and-10443-used:*) return 1 ;;
    *) return 1 ;;
    esac
}

MOCK_SCENARIO=all-free
assert_eq 443 "$(tuic_suggest_listen_port)" \
    "TUIC suggestion should prefer UDP/443 when it is free"

MOCK_SCENARIO=tcp443-used-only
assert_eq 443 "$(tuic_suggest_listen_port)" \
    "TCP/443 occupancy should not affect TUIC UDP/443 suggestion"

MOCK_SCENARIO=udp443-used
assert_eq 10443 "$(tuic_suggest_listen_port)" \
    "TUIC suggestion should fall back to UDP/10443 when UDP/443 is used"

MOCK_SCENARIO=udp443-and-10443-used
random_port=$(tuic_suggest_listen_port) || fail "TUIC suggestion should find a random UDP port"
[[ $random_port =~ ^[1-9][0-9]*$ ]] || fail "random suggestion should be numeric"
[[ $random_port -ge 10000 && $random_port -le 65535 ]] || fail "random suggestion should be in 10000-65535"
[[ $random_port != 443 && $random_port != 10443 ]] || fail "random suggestion should avoid UDP/443 and UDP/10443"
pass "TUIC menu suggestion function checks"
