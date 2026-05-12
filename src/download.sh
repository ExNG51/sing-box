make_tmpdir() {
    mktemp -d "${TMPDIR:-/tmp}/sing-box-download.XXXXXX" || err "创建临时目录失败."
}

verify_https_url() {
    case $1 in
    https://*) ;;
    *) err "拒绝非 HTTPS 下载地址: $1" ;;
    esac
}

verify_sha256() {
    local file=$1
    local expected=${2#sha256:}
    local actual
    [[ -f $file ]] || err "无法校验不存在的文件: $file"
    [[ $expected ]] || err "缺少 SHA256 校验值: $file"
    if type -P sha256sum >/dev/null; then
        actual=$(sha256sum "$file" | awk '{print $1}')
    elif type -P shasum >/dev/null; then
        actual=$(shasum -a 256 "$file" | awk '{print $1}')
    else
        err "缺少 sha256sum 或 shasum, 无法校验下载文件."
    fi
    [[ $actual == "$expected" ]] || err "SHA256 校验失败: $file"
}

download_to_file() {
    local url=$1
    local output=$2
    verify_https_url "$url"
    _wget -t 5 -q -O "$output" "$url"
}

get_github_asset_digest() {
    local repo=$1
    local tag=$2
    local asset=$3
    local api json_file digest
    if [[ $tag == "latest" ]]; then
        api="https://api.github.com/repos/${repo}/releases/latest?v=$RANDOM"
    else
        api="https://api.github.com/repos/${repo}/releases/tags/${tag}?v=$RANDOM"
    fi
    json_file="$tmpdir/github-${repo//\//-}-${tag}.json"
    download_to_file "$api" "$json_file" || return 1
    digest=$(awk -v asset="$asset" '
        /"name":/ {
            name=$0
            sub(/^.*"name"[[:space:]]*:[[:space:]]*"/, "", name)
            sub(/".*$/, "", name)
        }
        /"digest":/ {
            digest=$0
            sub(/^.*"digest"[[:space:]]*:[[:space:]]*"/, "", digest)
            sub(/".*$/, "", digest)
            if (name == asset && digest != "null") {
                print digest
                exit
            }
        }
    ' "$json_file")
    [[ $digest ]] || err "无法获取 ${repo} ${tag} ${asset} 的 SHA256 digest."
    echo "$digest"
}

get_latest_version() {
    case $1 in
    core)
        name=$is_core_name
        url="https://api.github.com/repos/${is_core_repo}/releases/latest?v=$RANDOM"
        ;;
    sh)
        name="$is_core_name 脚本"
        url="https://api.github.com/repos/$is_sh_repo/releases/latest?v=$RANDOM"
        ;;
    caddy)
        name="Caddy"
        url="https://api.github.com/repos/$is_caddy_repo/releases/latest?v=$RANDOM"
        ;;
    esac
    latest_ver=$(_wget -qO- "$url" | grep tag_name | grep -E -o 'v([0-9.]+)')
    [[ ! $latest_ver ]] && {
        err "获取 ${name} 最新版本失败."
    }
    unset name url
}

download() {
    latest_ver=$2
    if [[ ! $latest_ver && $1 == core ]]; then
        if [[ ${IS_USE_LATEST_VERSION:-false} == true ]]; then
            get_latest_version "$1"
        else
            latest_ver=$DEFAULT_SING_BOX_STABLE_VERSION
        fi
    elif [[ ! $latest_ver ]]; then
        get_latest_version "$1"
    fi
    tmpdir=$(make_tmpdir)
    expected_sha256=
    case $1 in
    core)
        name=$is_core_name
        asset="${is_core}-${latest_ver:1}-linux-${is_arch}.tar.gz"
        tmpfile=$tmpdir/$asset
        link="https://github.com/${is_core_repo}/releases/download/${latest_ver}/${asset}"
        expected_sha256=$(get_github_asset_digest "$is_core_repo" "$latest_ver" "$asset")
        download_file
        backup_path_before_write "$is_core_bin"
        tar zxf "$tmpfile" --strip-components 1 -C "$is_core_dir/bin"
        [[ -f $is_core_bin ]] || {
            rm -rf "$tmpdir"
            err "${name} 压缩包中未找到可执行文件."
        }
        safe_chmod_path +x "$is_core_bin"
        ;;
    sh)
        name="$is_core_name 脚本"
        asset=code.tar.gz
        tmpfile=$tmpdir/sh.tar.gz
        link="https://github.com/${is_sh_repo}/releases/download/${latest_ver}/${asset}"
        expected_sha256=$(get_github_asset_digest "$is_sh_repo" "$latest_ver" "$asset")
        download_file
        backup_path_before_write "$is_sh_dir"
        tar zxf "$tmpfile" -C "$is_sh_dir"
        safe_chmod_path +x "$is_sh_dir/$is_core.sh" "$is_sh_bin" "${is_sh_bin/$is_core/sb}"
        ;;
    caddy)
        name="Caddy"
        asset="caddy_${latest_ver:1}_linux_${is_arch}.tar.gz"
        tmpfile=$tmpdir/$asset
        link="https://github.com/${is_caddy_repo}/releases/download/${latest_ver}/${asset}"
        expected_sha256=$(get_github_asset_digest "$is_caddy_repo" "$latest_ver" "$asset")
        download_file
        tar zxf "$tmpfile" -C "$tmpdir"
        [[ -f $tmpdir/caddy ]] || {
            rm -rf "$tmpdir"
            err "${name} 压缩包中未找到可执行文件."
        }
        safe_copy_file "$tmpdir/caddy" "$is_caddy_bin"
        safe_chmod_path 0755 "$is_caddy_bin"
        ;;
    esac
    rm -rf "$tmpdir"
    unset latest_ver expected_sha256 asset
}

download_file() {
    if ! download_to_file "$link" "$tmpfile"; then
        rm -rf "$tmpdir"
        err "\n下载 ${name} 失败.\n"
    fi
    verify_sha256 "$tmpfile" "$expected_sha256"
}
