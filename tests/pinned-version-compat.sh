#!/usr/bin/env bash
set -euo pipefail

fail() {
    printf '[FAIL] %s\n' "$1" >&2
    exit 1
}

skip() {
    printf '[SKIP] %s\n' "$1"
    exit 0
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

# shellcheck disable=SC1091
. "$REPO_ROOT/src/version.sh"

VERSION="$DEFAULT_SING_BOX_STABLE_VERSION"
REPO="SagerNet/sing-box"
CONFIG_JSON="$TEST_ROOT/etc/sing-box/config.json"
CONF_DIR="$TEST_ROOT/etc/sing-box/conf"
TLS_TMP="$TEST_ROOT/tls.tmp"
TLS_KEY="$TEST_ROOT/tls.key"
TLS_CERT="$TEST_ROOT/tls.cer"
mkdir -p "$CONF_DIR" "$TEST_ROOT/download" "$TEST_ROOT/extract"

case "$(uname -s)" in
Linux) release_os=linux ;;
Darwin) release_os=darwin ;;
*) fail "unsupported OS for compatibility check: $(uname -s)" ;;
esac

case "$(uname -m)" in
x86_64 | amd64) release_arch=amd64 ;;
arm64 | aarch64) release_arch=arm64 ;;
*) fail "unsupported arch for compatibility check: $(uname -m)" ;;
esac

asset="sing-box-${VERSION#v}-${release_os}-${release_arch}.tar.gz"
release_api="https://api.github.com/repos/${REPO}/releases/tags/${VERSION}"
release_json="$TEST_ROOT/download/release.json"
archive="$TEST_ROOT/download/$asset"

if ! command -v curl >/dev/null 2>&1; then
    skip "curl is not available; skipping network compatibility test"
fi

if ! command -v jq >/dev/null 2>&1; then
    skip "jq is not available; skipping network compatibility test"
fi

if ! command -v tar >/dev/null 2>&1; then
    skip "tar is not available; skipping network compatibility test"
fi

if ! curl -fsSL --connect-timeout 5 --max-time 10 "https://api.github.com/repos/${REPO}" >/dev/null 2>&1; then
    skip "api.github.com is unreachable; skipping pinned-version compatibility test"
fi

download_https_or_skip() {
    local url=$1
    local output=$2
    local http_code
    case $url in
    https://*) ;;
    *) fail "refusing non-HTTPS URL: $url" ;;
    esac
    if ! http_code=$(curl -sSL --connect-timeout 10 --max-time 120 -w '%{http_code}' "$url" -o "$output"); then
        rm -f "$output"
        skip "network download failed for $url; skipping pinned-version compatibility test"
    fi
    case $http_code in
    2*) ;;
    *) fail "HTTP $http_code downloading $url" ;;
    esac
}

verify_sha256_digest() {
    local file=$1
    local expected=${2#sha256:}
    local actual

    [[ $expected ]] || fail "missing SHA256 digest for $file"
    if command -v sha256sum >/dev/null 2>&1; then
        actual=$(sha256sum "$file" | awk '{print $1}')
    else
        actual=$(shasum -a 256 "$file" | awk '{print $1}')
    fi
    [[ $actual == "$expected" ]] || fail "SHA256 mismatch for $file"
}

download_https_or_skip "$release_api" "$release_json"
download_url="$(jq -r --arg name "$asset" '.assets[] | select(.name == $name) | .browser_download_url // empty' "$release_json")"
digest="$(jq -r --arg name "$asset" '.assets[] | select(.name == $name) | .digest // empty' "$release_json")"
[[ $download_url ]] || fail "asset not found in release: $asset"
[[ $digest == sha256:* ]] || fail "GitHub release digest not found for asset: $asset"

download_https_or_skip "$download_url" "$archive"
verify_sha256_digest "$archive" "$digest"
tar -xzf "$archive" -C "$TEST_ROOT/extract" || fail "failed to extract release archive: $asset"
SING_BOX_BIN="$(find "$TEST_ROOT/extract" -type f -name sing-box | head -n 1)"
[[ -x $SING_BOX_BIN ]] || chmod +x "$SING_BOX_BIN"
"$SING_BOX_BIN" version | grep -Fq "${VERSION#v}" || fail "downloaded sing-box is not $VERSION"

"$SING_BOX_BIN" generate tls-keypair tls -m 456 >"$TLS_TMP"
awk '/BEGIN PRIVATE KEY/,/END PRIVATE KEY/' "$TLS_TMP" >"$TLS_KEY"
awk '/BEGIN CERTIFICATE/,/END CERTIFICATE/' "$TLS_TMP" >"$TLS_CERT"
[[ -s $TLS_KEY && -s $TLS_CERT ]] || fail 'failed to generate TLS keypair'

uuid="$("$SING_BOX_BIN" generate uuid)"
reality_pair="$("$SING_BOX_BIN" generate reality-keypair)"
private_key="$(awk -F: '/PrivateKey/ { gsub(/[[:space:]]/, "", $2); print $2; exit }' <<<"$reality_pair")"
[[ $private_key ]] || fail 'failed to parse Reality private key'
ss2022_password="MTIzNDU2Nzg5MDEyMzQ1Ng=="

write_base_config() {
    cat >"$CONFIG_JSON" <<EOF
{
  "log": {
    "level": "info"
  },
  "outbounds": [
    {
      "tag": "direct",
      "type": "direct"
    }
  ]
}
EOF
}

check_protocol_config() {
    local name=$1
    local file="$CONF_DIR/$name.json"

    rm -rf "$CONF_DIR"
    mkdir -p "$CONF_DIR"
    write_base_config
    cat >"$file"
    "$SING_BOX_BIN" check -c "$CONFIG_JSON" -C "$CONF_DIR" >/tmp/sing-box-check-"$name".out 2>&1 || {
        cat /tmp/sing-box-check-"$name".out >&2
        fail "sing-box check failed for $name"
    }
    printf '[CHECK] %s\n' "$name"
}

check_protocol_config anytls <<EOF
{
  "inbounds": [
    {
      "tag": "anytls-test",
      "type": "anytls",
      "listen": "127.0.0.1",
      "listen_port": 21001,
      "users": [
        {
          "password": "test-password"
        }
      ],
      "tls": {
        "enabled": true,
        "key_path": "$TLS_KEY",
        "certificate_path": "$TLS_CERT"
      }
    }
  ]
}
EOF

check_protocol_config vless-reality <<EOF
{
  "inbounds": [
    {
      "tag": "vless-reality-test",
      "type": "vless",
      "listen": "127.0.0.1",
      "listen_port": 21002,
      "users": [
        {
          "flow": "xtls-rprx-vision",
          "uuid": "$uuid"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "www.cloudflare.com",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "www.cloudflare.com",
            "server_port": 443
          },
          "private_key": "$private_key",
          "short_id": [
            ""
          ]
        }
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct"
    },
    {
      "tag": "public_key_placeholder",
      "type": "direct"
    }
  ]
}
EOF

check_protocol_config vless-http2-reality <<EOF
{
  "inbounds": [
    {
      "tag": "vless-http2-reality-test",
      "type": "vless",
      "listen": "127.0.0.1",
      "listen_port": 21003,
      "users": [
        {
          "uuid": "$uuid"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "www.cloudflare.com",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "www.cloudflare.com",
            "server_port": 443
          },
          "private_key": "$private_key",
          "short_id": [
            ""
          ]
        }
      },
      "transport": {
        "type": "http"
      }
    }
  ]
}
EOF

check_protocol_config tuic <<EOF
{
  "inbounds": [
    {
      "tag": "tuic-test",
      "type": "tuic",
      "listen": "127.0.0.1",
      "listen_port": 21004,
      "users": [
        {
          "uuid": "$uuid",
          "password": "test-password"
        }
      ],
      "congestion_control": "bbr",
      "tls": {
        "enabled": true,
        "key_path": "$TLS_KEY",
        "certificate_path": "$TLS_CERT"
      }
    }
  ]
}
EOF

check_protocol_config hysteria2 <<EOF
{
  "inbounds": [
    {
      "tag": "hysteria2-test",
      "type": "hysteria2",
      "listen": "127.0.0.1",
      "listen_port": 21005,
      "users": [
        {
          "password": "test-password"
        }
      ],
      "tls": {
        "enabled": true,
        "key_path": "$TLS_KEY",
        "certificate_path": "$TLS_CERT"
      }
    }
  ]
}
EOF

check_protocol_config shadowsocks-2022 <<EOF
{
  "inbounds": [
    {
      "tag": "shadowsocks-2022-test",
      "type": "shadowsocks",
      "listen": "127.0.0.1",
      "listen_port": 21006,
      "method": "2022-blake3-aes-128-gcm",
      "password": "$ss2022_password"
    }
  ]
}
EOF

check_protocol_config trojan <<EOF
{
  "inbounds": [
    {
      "tag": "trojan-test",
      "type": "trojan",
      "listen": "127.0.0.1",
      "listen_port": 21007,
      "users": [
        {
          "password": "test-password"
        }
      ],
      "tls": {
        "enabled": true,
        "key_path": "$TLS_KEY",
        "certificate_path": "$TLS_CERT"
      }
    }
  ]
}
EOF

check_protocol_config vmess-ws <<EOF
{
  "inbounds": [
    {
      "tag": "vmess-ws-test",
      "type": "vmess",
      "listen": "127.0.0.1",
      "listen_port": 21008,
      "users": [
        {
          "uuid": "$uuid"
        }
      ],
      "transport": {
        "type": "ws",
        "path": "/ws",
        "early_data_header_name": "Sec-WebSocket-Protocol"
      }
    }
  ]
}
EOF

check_protocol_config vmess-ws-tls <<EOF
{
  "inbounds": [
    {
      "tag": "vmess-ws-tls-test",
      "type": "vmess",
      "listen": "127.0.0.1",
      "listen_port": 21009,
      "users": [
        {
          "uuid": "$uuid"
        }
      ],
      "tls": {
        "enabled": true,
        "alpn": [
          "h2",
          "http/1.1"
        ],
        "key_path": "$TLS_KEY",
        "certificate_path": "$TLS_CERT"
      },
      "transport": {
        "type": "ws",
        "path": "/ws",
        "headers": {
          "host": "example.com"
        },
        "early_data_header_name": "Sec-WebSocket-Protocol"
      }
    }
  ]
}
EOF

check_protocol_config vless-ws-tls <<EOF
{
  "inbounds": [
    {
      "tag": "vless-ws-tls-test",
      "type": "vless",
      "listen": "127.0.0.1",
      "listen_port": 21010,
      "users": [
        {
          "uuid": "$uuid"
        }
      ],
      "tls": {
        "enabled": true,
        "alpn": [
          "h2",
          "http/1.1"
        ],
        "key_path": "$TLS_KEY",
        "certificate_path": "$TLS_CERT"
      },
      "transport": {
        "type": "ws",
        "path": "/ws",
        "headers": {
          "host": "example.com"
        }
      }
    }
  ]
}
EOF

check_protocol_config socks <<EOF
{
  "inbounds": [
    {
      "tag": "socks-test",
      "type": "socks",
      "listen": "127.0.0.1",
      "listen_port": 21011,
      "users": [
        {
          "username": "user",
          "password": "test-password"
        }
      ]
    }
  ]
}
EOF

printf '[PASS] pinned sing-box %s compatibility checks\n' "$VERSION"
