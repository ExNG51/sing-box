#!/bin/bash

DEFAULT_SING_BOX_STABLE_VERSION=${DEFAULT_SING_BOX_STABLE_VERSION:-v1.13.8}
IS_USE_LATEST_VERSION=${IS_USE_LATEST_VERSION:-false}
IS_USER_CORE_VERSION_SPECIFIED=${IS_USER_CORE_VERSION_SPECIFIED:-false}
VERSION_POLICY_REQUESTED_VERSION=
VERSION_POLICY_USE_LATEST=false

version_policy_notice() {
    printf '%s\n' "$*" >&2
}

version_policy_die() {
    if type err >/dev/null 2>&1; then
        err "$*"
    else
        printf 'ERROR: %s\n' "$*" >&2
    fi
    return 1
}

normalize_core_version() {
    local version=$1
    [[ $version ]] || return 0
    printf 'v%s' "${version#v}"
}

resolve_core_version_policy() {
    local requested_version=${1:-}
    local use_latest=${2:-false}
    local normalized

    # 版本来源只能有一个，避免用户以为 pin 生效但实际追 latest。
    if [[ $requested_version && $use_latest == true ]]; then
        version_policy_die "Cannot use --latest and --core-version at the same time."
        return 1
    fi

    if [[ $requested_version ]]; then
        normalized=$(normalize_core_version "$requested_version")
        version_policy_notice "Using user-specified sing-box version: $normalized"
        printf '%s\n' "$normalized"
        return 0
    fi

    if [[ $use_latest == true ]]; then
        type get_latest_version >/dev/null 2>&1 || {
            version_policy_die "latest release resolver is unavailable."
            return 1
        }
        version_policy_notice "Using latest sing-box release. This may introduce breaking changes."
        get_latest_version core || return 1
        printf '%s\n' "$latest_ver"
        return 0
    fi

    version_policy_notice "Using pinned stable sing-box version: $DEFAULT_SING_BOX_STABLE_VERSION"
    printf '%s\n' "$DEFAULT_SING_BOX_STABLE_VERSION"
}

parse_core_version_policy_args() {
    VERSION_POLICY_REQUESTED_VERSION=
    VERSION_POLICY_USE_LATEST=false

    while [[ $# -gt 0 ]]; do
        case $1 in
        --latest)
            VERSION_POLICY_USE_LATEST=true
            shift
            ;;
        -v | --core-version)
            [[ ${2:-} ]] || {
                version_policy_die "($1) 缺少必需参数, 正确使用示例: $1 v1.13.8"
                return 1
            }
            VERSION_POLICY_REQUESTED_VERSION=$2
            shift 2
            ;;
        -*)
            version_policy_die "未知版本参数: $1"
            return 1
            ;;
        *)
            [[ ! $VERSION_POLICY_REQUESTED_VERSION ]] || {
                version_policy_die "只能指定一个 sing-box core 版本."
                return 1
            }
            VERSION_POLICY_REQUESTED_VERSION=$1
            shift
            ;;
        esac
    done

    if [[ $VERSION_POLICY_REQUESTED_VERSION && $VERSION_POLICY_USE_LATEST == true ]]; then
        version_policy_die "Cannot use --latest and --core-version at the same time."
        return 1
    fi
}
