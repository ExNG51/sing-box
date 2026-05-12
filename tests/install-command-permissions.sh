#!/usr/bin/env bash
set -euo pipefail

fail() {
    printf '[FAIL] %s\n' "$1" >&2
    exit 1
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

shopt -s nullglob
for file in install.sh sing-box.sh src/*.sh; do
    bash -n "$file"
done

assert_match 'safe_chmod_path \+x "\$is_core_bin" "\$is_sh_dir/\$is_core\.sh"' install.sh \
    'installer must chmod the management script target before running /usr/local/bin/sing-box'

assert_match 'safe_chmod_path \+x "\$is_sh_dir/\$is_core\.sh"' src/download.sh \
    'script update must chmod the management script target, not only command symlinks'

assert_match 'run: bash tests/install-command-permissions\.sh' .github/workflows/release.yml \
    'release workflow must run command permission checks before packaging'

awk '
    /run: bash tests\/install-command-permissions\.sh/ { check_line = NR }
    /- name: tar/ { tar_line = NR }
    END { exit !(check_line && tar_line && check_line < tar_line) }
' .github/workflows/release.yml || fail 'release workflow command permission checks must run before the tar step'

printf '[PASS] install command permission checks\n'
