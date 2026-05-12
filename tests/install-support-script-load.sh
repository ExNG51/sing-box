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

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

FAKEBIN="$TEST_ROOT/bin"
TAR_LOG="$TEST_ROOT/tar.log"
mkdir -p "$FAKEBIN" "$TEST_ROOT/work" "$TEST_ROOT/tmp"
: >"$TAR_LOG"
: >"$TEST_ROOT/code.tar.gz"

cat >"$FAKEBIN/tar" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

dest=
member=
while [[ $# -gt 0 ]]; do
    case $1 in
    -C)
        dest=$2
        shift 2
        ;;
    *)
        member=$1
        shift
        ;;
    esac
done

printf '%s\n' "$member" >>"$TAR_LOG"
[[ $dest ]] || exit 1

case $member in
./src/backup.sh)
    mkdir -p "$dest/src"
    cat >"$dest/src/backup.sh" <<'BACKUP'
safe_write_file() {
    :
}
BACKUP
    ;;
src/backup.sh)
    exit 1
    ;;
*)
    exit 1
    ;;
esac
EOF
chmod +x "$FAKEBIN/tar"

definitions=$(awk '
    /^err\(\)/,/^}/ { print }
    /^load_install_support_script\(\)/,/^}/ { print }
    /^ensure_backup_functions_loaded\(\)/,/^}/ { print }
' "$REPO_ROOT/install.sh")

is_err='ERROR!'
tmpdir="$TEST_ROOT/tmp"
is_sh_ok="$TEST_ROOT/code.tar.gz"
export TAR_LOG

# shellcheck disable=SC1090
eval "$definitions"

set +e
(
    cd "$TEST_ROOT/work"
    PATH="$FAKEBIN:/usr/bin:/bin:/usr/sbin:/sbin" ensure_backup_functions_loaded
)
status=$?
set -e

[[ $status -eq 0 ]] || fail 'installer must load backup.sh from release tarballs that require ./src member names'
assert_contains "$TAR_LOG" 'src/backup.sh' 'installer must first try the historical support member path'
assert_contains "$TAR_LOG" './src/backup.sh' 'installer must retry support member path with ./ prefix'

printf '[PASS] install support script loading checks\n'
