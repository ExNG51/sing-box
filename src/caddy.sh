caddy_config() {
    is_caddy_site_file=$is_caddy_conf/${host}.conf
    case $1 in
    new)
        safe_ensure_dir "$is_caddy_dir"
        safe_ensure_dir "$is_caddy_dir/sites"
        safe_ensure_dir "$is_caddy_conf"
        safe_write_file "$is_caddyfile" <<-EOF
# don't edit this file #
# 不要编辑这个文件 #
# https://caddyserver.com/docs/caddyfile/options
{
  admin off
  http_port $is_http_port
  https_port $is_https_port
}
import $is_caddy_conf/*.conf
import $is_caddy_dir/sites/*.conf
EOF
        ;;
    *ws* | *http*)
        safe_write_file "${is_caddy_site_file}" "
${host}:${is_https_port} {
    reverse_proxy ${path} 127.0.0.1:${port}
    import ${is_caddy_site_file}.add
}"
        ;;
    *h2*)
        safe_write_file "${is_caddy_site_file}" "
${host}:${is_https_port} {
    reverse_proxy ${path} h2c://127.0.0.1:${port} {
        transport http {
			tls_insecure_skip_verify
		}
    }
    import ${is_caddy_site_file}.add
}"
        ;;
    *grpc*)
        safe_write_file "${is_caddy_site_file}" "
${host}:${is_https_port} {
    reverse_proxy /${path}/* h2c://127.0.0.1:${port}
    import ${is_caddy_site_file}.add
}"
        ;;
    proxy)

        safe_write_file "${is_caddy_site_file}.add" "
reverse_proxy https://$proxy_site {
        header_up Host {upstream_hostport}
}"
        ;;
    esac
    [[ $1 != "new" && $1 != 'proxy' ]] && {
        [[ ! -f ${is_caddy_site_file}.add ]] && safe_write_file "${is_caddy_site_file}.add" "# custom Caddy directives"
    }
}
