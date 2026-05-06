#!/usr/bin/env bash
set -euo pipefail

fail() {
    printf '[FAIL] %s\n' "$1" >&2
    exit 1
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

FAKEBIN="$TMP_ROOT/bin"
ACTION_LOG="$TMP_ROOT/actions.log"
OS_RELEASE_FILE="$TMP_ROOT/os-release"
mkdir -p "$FAKEBIN"

cat >"$OS_RELEASE_FILE" <<'EOF'
PRETTY_NAME="Debian 12"
NAME="Debian"
VERSION_ID="12"
EOF

make_fake_command() {
    local name="$1"
    cat >"$FAKEBIN/$name" <<EOF
#!/usr/bin/env bash
printf '%s\n' "$name \$*" >> "$ACTION_LOG"
exit 42
EOF
    chmod +x "$FAKEBIN/$name"
}

for cmd in apt-get systemctl wget timedatectl update-ca-certificates ufw firewall-cmd iptables nft; do
    make_fake_command "$cmd"
done

cat >"$FAKEBIN/uname" <<'EOF'
#!/usr/bin/env bash
if [[ ${1:-} == "-m" ]]; then
    echo x86_64
else
    /usr/bin/uname "$@"
fi
EOF
chmod +x "$FAKEBIN/uname"

run_install() {
    local output="$1"
    shift
    PATH="$FAKEBIN:/usr/bin:/bin:/usr/sbin:/sbin" \
        OS_RELEASE_FILE="$OS_RELEASE_FILE" \
        bash "$REPO_ROOT/install.sh" "$@" >"$output" 2>&1
}

assert_contains() {
    local file="$1"
    local text="$2"
    local description="$3"
    grep -Fq -- "$text" "$file" || {
        cat "$file" >&2
        fail "$description"
    }
}

assert_not_contains() {
    local file="$1"
    local text="$2"
    local description="$3"
    if grep -Fq -- "$text" "$file"; then
        cat "$file" >&2
        fail "$description"
    fi
}

assert_no_actions() {
    local description="$1"
    if [[ -s $ACTION_LOG ]]; then
        cat "$ACTION_LOG" >&2
        fail "$description"
    fi
}

assert_plan_output() {
    local output="$1"
    assert_contains "$output" "Install Plan" 'install plan heading must be printed'
    assert_contains "$output" "System:" 'install plan must include System section'
    assert_contains "$output" "- OS: Debian 12" 'install plan must include detected OS'
    assert_contains "$output" "- Arch: amd64" 'install plan must include detected architecture'
    assert_contains "$output" "- Init: systemd" 'install plan must include init system'
    assert_contains "$output" "- Package manager: apt-get" 'install plan must include package manager'
    assert_contains "$output" "Downloads:" 'install plan must include Downloads section'
    assert_contains "$output" "release version will be resolved during execution" 'dry-run plan must not resolve release over network'
    assert_contains "$output" "Files to write:" 'install plan must include Files to write section'
    assert_contains "$output" "/usr/local/bin/sing-box" 'install plan must include sing-box command path'
    assert_contains "$output" "/usr/local/bin/sb" 'install plan must include sb command path'
    assert_contains "$output" "/etc/sing-box/config.json" 'install plan must include base config path'
    assert_contains "$output" "/etc/systemd/system/sing-box.service" 'install plan must include systemd unit path'
    assert_contains "$output" "Services:" 'install plan must include Services section'
    assert_contains "$output" "- create: sing-box.service" 'install plan must include service create action'
    assert_contains "$output" "- enable: sing-box.service" 'install plan must include service enable action'
    assert_contains "$output" "- start: sing-box.service" 'install plan must include service start action'
    assert_contains "$output" "Ports:" 'install plan must include Ports section'
    assert_contains "$output" "- none by default" 'install plan must state default install opens no ports'
}

dry_run_output="$TMP_ROOT/dry-run.out"
run_install "$dry_run_output" --dry-run || fail '--dry-run must exit 0'
assert_plan_output "$dry_run_output"
assert_not_contains "$dry_run_output" "Continue with this installation plan?" '--dry-run must not ask for confirmation'
assert_no_actions '--dry-run must not call download, package, or service commands'
dry_run_tmpdir="$(sed -n 's/^- temp directory: //p' "$dry_run_output" | tail -n 1)"
[[ -n $dry_run_tmpdir && ! -e $dry_run_tmpdir ]] || fail '--dry-run temp directory must be cleaned up'

plan_output="$TMP_ROOT/plan.out"
: >"$ACTION_LOG"
run_install "$plan_output" --plan || fail '--plan must exit 0'
assert_plan_output "$plan_output"
assert_not_contains "$plan_output" "Continue with this installation plan?" '--plan must not ask for confirmation'
assert_no_actions '--plan must behave like --dry-run'

dry_run_yes_output="$TMP_ROOT/dry-run-yes.out"
: >"$ACTION_LOG"
run_install "$dry_run_yes_output" --dry-run --yes || fail '--dry-run must take priority over --yes'
assert_plan_output "$dry_run_yes_output"
assert_not_contains "$dry_run_yes_output" "Continue with this installation plan?" '--dry-run --yes must not ask for confirmation'
assert_no_actions '--dry-run --yes must not execute installation'

if [[ $EUID != 0 ]]; then
    yes_output="$TMP_ROOT/yes.out"
    : >"$ACTION_LOG"
    set +e
    run_install "$yes_output" --yes
    yes_status=$?
    set -e
    [[ $yes_status -ne 0 ]] || fail '--yes should require root before executing on non-root test runs'
    assert_plan_output "$yes_output"
    assert_not_contains "$yes_output" "Continue with this installation plan?" '--yes must not ask for confirmation'
    assert_contains "$yes_output" "ROOT用户" '--yes must reach the root execution gate on non-root test runs'
    assert_no_actions '--yes root gate must run before download, package, or service commands'
fi

cancel_output="$TMP_ROOT/cancel.out"
: >"$ACTION_LOG"
printf 'n\n' | PATH="$FAKEBIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    OS_RELEASE_FILE="$OS_RELEASE_FILE" \
    bash "$REPO_ROOT/install.sh" >"$cancel_output" 2>&1 || fail 'declining confirmation must exit 0'
assert_plan_output "$cancel_output"
assert_contains "$cancel_output" "Continue with this installation plan? [y/N]" 'normal install must ask for confirmation'
assert_contains "$cancel_output" "Installation cancelled." 'declining confirmation must report cancellation'
assert_not_contains "$cancel_output" "ROOT用户" 'declining confirmation must not require root before exiting'
assert_no_actions 'declining confirmation must not call download, package, or service commands'

printf '[PASS] install plan and dry-run checks\n'
