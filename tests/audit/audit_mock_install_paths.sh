#!/usr/bin/env bash
set -euo pipefail

fail() {
    printf '[FAIL] %s\n' "$1" >&2
    exit 1
}

assert_contains() {
    local file=$1
    local text=$2
    local description=$3
    grep -Fq -- "$text" "$file" || {
        cat "$file" >&2
        fail "$description"
    }
}

assert_no_actions() {
    local action_log=$1
    local description=$2
    if [[ -s $action_log ]]; then
        cat "$action_log" >&2
        fail "$description"
    fi
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
AUDIT_DIR="$REPO_ROOT/.audit-tmp"
mkdir -p "$AUDIT_DIR"
TEST_ROOT="$(mktemp -d "$AUDIT_DIR/mock-install-root.XXXXXX")"
MOCK_BIN="$TEST_ROOT/mock-bin"
MOCK_LOG="$TEST_ROOT/mock-commands.log"
OS_RELEASE_FILE="$TEST_ROOT/os-release"
INSTALL_OUT="$TEST_ROOT/install-dry-run.out"
EXECUTE_BLOCK="$TEST_ROOT/execute_install.block"
LOG="$AUDIT_DIR/mock-install-paths.log"
mkdir -p "$MOCK_BIN" "$TEST_ROOT/tmp"
: >"$MOCK_LOG"
: >"$LOG"

exec >>"$LOG" 2>&1

cat >"$OS_RELEASE_FILE" <<'EOF'
PRETTY_NAME="Debian 12"
NAME="Debian"
VERSION_ID="12"
EOF

make_fake_command() {
    local name=$1
    cat >"$MOCK_BIN/$name" <<EOF
#!/usr/bin/env bash
printf '%s\n' "$name \$*" >> "$MOCK_LOG"
exit 42
EOF
    chmod +x "$MOCK_BIN/$name"
}

for cmd in apt-get systemctl wget timedatectl update-ca-certificates ufw firewall-cmd iptables nft tar jq sing-box; do
    make_fake_command "$cmd"
done

cat >"$MOCK_BIN/uname" <<'EOF'
#!/usr/bin/env bash
if [[ ${1:-} == "-m" ]]; then
    echo x86_64
else
    /usr/bin/uname "$@"
fi
EOF
chmod +x "$MOCK_BIN/uname"

PATH="$MOCK_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    OS_RELEASE_FILE="$OS_RELEASE_FILE" \
    TMPDIR="$TEST_ROOT/tmp" \
    bash "$REPO_ROOT/install.sh" --dry-run >"$INSTALL_OUT" 2>&1 || fail 'install.sh --dry-run must exit 0'

assert_contains "$INSTALL_OUT" 'Install Plan' 'dry-run must print install plan'
assert_contains "$INSTALL_OUT" 'Ports:' 'dry-run must print ports section'
assert_contains "$INSTALL_OUT" 'none by default' 'dry-run must state no default ports'
assert_contains "$INSTALL_OUT" 'protocol ports will be opened only after user explicitly adds an inbound from the menu' 'dry-run must state protocols are manual'
assert_contains "$INSTALL_OUT" 'Using pinned stable sing-box version: v1.13.8' 'dry-run must use pinned stable by default'
assert_no_actions "$MOCK_LOG" 'dry-run must not execute mocked package, download, service, or tar commands'

awk '/execute_install\(\)/,/^}/ { print }' "$REPO_ROOT/install.sh" >"$EXECUTE_BLOCK"
if rg -n '^[[:space:]]*(sb|sing-box)?[[:space:]]*add[[:space:]]+|create[[:space:]]+server|VLESS-REALITY|AnyTLS|TUIC' "$EXECUTE_BLOCK" >"$TEST_ROOT/install-auto-protocol-matches.out" 2>&1; then
    cat "$TEST_ROOT/install-auto-protocol-matches.out" >&2
    fail 'execute_install must not create protocol configs'
fi

rg -n 'open_main_menu_if_interactive|\[ -t 0 \].*\[ -t 1 \]|show_install_complete' "$REPO_ROOT/install.sh" >"$TEST_ROOT/install-interactive-gate.out"
assert_contains "$TEST_ROOT/install-interactive-gate.out" '[ -t 0 ] && [ -t 1 ]' 'post-install menu must be TTY gated'

printf '[PASS] mock install path audit root: %s\n' "$TEST_ROOT"
