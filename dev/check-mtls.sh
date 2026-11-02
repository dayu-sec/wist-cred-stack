#!/usr/bin/env bash
# 用「X 自己登记到手的那份材料」+ cred 的客户端证书，跑一次真实的双向 TLS 握手。
#
# 用法：
#   dev/check-mtls.sh [X 的材料目录] [PKI 目录] [端口]
#     dev/check-mtls.sh /tmp/wist-e2e/install dev/identity 19445
#
# 只做握手 + 双方证书校验，不涉及业务协议。
set -uo pipefail

X_DIR="${1:-/tmp/wist-e2e/install}"
PKI="${2:-dev/identity}"
PORT="${3:-19445}"

for f in "$X_DIR/server.crt" "$X_DIR/server.key" "$X_DIR/client-ca.pem" \
         "$PKI/cred-client.crt" "$PKI/cred-client.key" "$PKI/ca-s.crt"; do
  [[ -f "$f" ]] || { echo "缺少材料：$f" >&2; exit 2; }
done

cleanup() { [[ -n "${SRV:-}" ]] && kill -9 "${SRV}" 2>/dev/null; }
trap cleanup EXIT

# X 侧：自己的服务器证书 + 只认 CA-I 签的客户端证书
openssl s_server -accept "${PORT}" \
  -cert "$X_DIR/server.crt" -key "$X_DIR/server.key" \
  -CAfile "$X_DIR/client-ca.pem" -Verify 1 -verify_return_error \
  -naccept 1 -quiet >/tmp/wist-mtls-server.log 2>&1 &
SRV=$!
sleep 1

# cred 侧：自己的客户端证书 + 只认 CA-S 签的服务器证书
echo "ping" | openssl s_client -connect "127.0.0.1:${PORT}" \
  -cert "$PKI/cred-client.crt" -key "$PKI/cred-client.key" \
  -CAfile "$PKI/ca-s.crt" -verify_return_error -brief 2>&1
CLIENT_RC=$?

sleep 0.5
echo "--- client rc=${CLIENT_RC} ---"
echo "--- server log ---"
cat /tmp/wist-mtls-server.log
