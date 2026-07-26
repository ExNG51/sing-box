#!/usr/bin/env bash

# Return the single valid manager-version declaration from the launcher.
manager_version_from_launcher() {
    local launcher=${1:-}
    local declaration_count version

    [[ -f $launcher ]] || return 1
    declaration_count=$(grep -Ec '^is_sh_ver=' "$launcher" || true)
    [[ $declaration_count -eq 1 ]] || return 1

    version=$(sed -n 's/^is_sh_ver=//p' "$launcher")
    [[ $version =~ ^v[0-9]+(\.[0-9]+)+$ ]] || return 1
    printf '%s\n' "$version"
}
