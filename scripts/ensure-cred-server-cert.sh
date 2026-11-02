#!/usr/bin/env bash
# 生成/校验入口（wist-cred-web 的 nginx）用的站点身份：identity/cred/server.{crt,key}。
#
# 用法：
#   scripts/ensure-cred-server-cert.sh <identity_dir> <domain>
#
# 阶段一用**自签**：只有本栈的 nginx 用它终止 TLS，没有第三方需要校这条链。
# 换成正式证书时，把 server.crt / server.key 覆盖进去即可（脚本缺省即跳过，不会重生成）。
#
# 幂等：证书与私钥都在就跳过 —— 重新生成会让浏览器已接受的证书失效。
set -euo pipefail

IDENTITY_DIR="${1:-identity/cred}"
DOMAIN="${2:-}"

if [[ -z "${DOMAIN}" ]]; then
  echo "用法: $0 <identity_dir> <domain>" >&2
  exit 2
fi

CRT="${IDENTITY_DIR}/server.crt"
KEY="${IDENTITY_DIR}/server.key"

if [[ -f "${CRT}" && -f "${KEY}" ]]; then
  echo "  站点证书已存在，跳过：${CRT}"
  exit 0
fi

mkdir -p "${IDENTITY_DIR}"

# 用临时配置文件写 SAN：`openssl req -addext` 在 LibreSSL（macOS 自带）上不可用。
tmp_conf="$(mktemp "${IDENTITY_DIR}/.openssl.XXXXXX")"
trap 'rm -f "${tmp_conf}"' EXIT
cat >"${tmp_conf}" <<EOF
[req]
distinguished_name = dn
x509_extensions    = v3
prompt             = no

[dn]
CN = ${DOMAIN}

[v3]
subjectAltName = DNS:${DOMAIN}
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 825 \
  -keyout "${KEY}" -out "${CRT}" -config "${tmp_conf}" >/dev/null 2>&1

chmod 600 "${KEY}"
chmod 644 "${CRT}"
echo "  已生成自签站点证书：${CRT}（CN=${DOMAIN}）"
