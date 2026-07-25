 #!/usr/bin/env bash
 set -uo pipefail
 
 # Optimization Area 2: Client URL parameter compatibility & Hysteria2 cert fingerprint checks.
 
 fail() {
     printf '[FAIL] %s\n' "$1" >&2
     exit 1
 }
 
 REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
 TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/sb-url-compat.XXXXXX")"
 trap 'rm -rf "$TEST_ROOT"' EXIT
 
 is_core=sing-box
 is_core_dir="$TEST_ROOT/etc/sing-box"
 is_conf_dir="$is_core_dir/conf"
 is_config_json="$is_core_dir/config.json"
 is_backup_dir="$is_core_dir/backups"
 is_core_bin="$TEST_ROOT/usr/local/bin/sing-box"
 is_sh_bin="$TEST_ROOT/usr/local/bin/sb"
 
 err() { printf 'ERROR: %s\n' "$*" >&2; return 1; }
 warn() { printf 'WARN: %s\n' "$*" >&2; }
 ui_warn() { warn "$*"; }
 ui_print() { printf '%b\n' "$*"; }
 ui_blank() { :; }
 ui_kv() { :; }
 
 mkdir -p "$is_conf_dir" "$is_backup_dir"
 
 # --- 1. Static checks for dual insecure parameters in src/core.sh and src/tuic.sh ---
 grep -q 'type=tcp&security=tls&insecure=1&allowInsecure=1' "$REPO_ROOT/src/core.sh" || \
     fail "src/core.sh Trojan URL must render insecure=1&allowInsecure=1"
 
 grep -q 'insecure=1&allow_insecure=1&congestion_control=bbr' "$REPO_ROOT/src/core.sh" || \
     fail "src/core.sh TUIC legacy URL must render insecure=1&allow_insecure=1"
 
 grep -q 'anytls://.*insecure=1&allowInsecure=1' "$REPO_ROOT/src/core.sh" || \
     fail "src/core.sh AnyTLS legacy URL must render insecure=1&allowInsecure=1"
 
 grep -q 'insecure=1&allow_insecure=1' "$REPO_ROOT/src/tuic.sh" || \
     fail "src/tuic.sh structured TUIC URL must render insecure=1&allow_insecure=1"
 
 grep -q 'pinSHA256' "$REPO_ROOT/src/core.sh" || \
     fail "src/core.sh Hysteria2 URL must support pinSHA256 fingerprint"
 
 # --- 2. Dynamic test for structured TUIC URL rendering ---
 # shellcheck disable=SC1091
 . "$REPO_ROOT/src/backup.sh"
 # shellcheck disable=SC1091
 . "$REPO_ROOT/src/tuic.sh"
 
 tuic_reset_state
 tuic_insecure=1
 tuic_requested_tls=
 tuic_cert_file_arg=
 tuic_key_file_arg=
tuic_cert_file=""
tuic_key_file=""
 tuic_domain=
 tuic_port=10443
 tuic_uuid="11111111-1111-1111-1111-111111111111"
 tuic_password="pass"
 tuic_cc="bbr"
 tuic_tls_mode="self-signed-insecure"
 
 tuic_json=$(tuic_render_inbound_json)
 rendered_url=$(tuic_render_client_url "$tuic_json")
 
 [[ $rendered_url == *"insecure=1"* ]] || fail "structured TUIC URL must contain insecure=1"
 [[ $rendered_url == *"allow_insecure=1"* ]] || fail "structured TUIC URL must contain allow_insecure=1"
 
 printf '[PASS] client URL compatibility checks\n'
