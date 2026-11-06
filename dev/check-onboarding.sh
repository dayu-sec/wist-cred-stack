#!/usr/bin/env bash
# 端到端：mint → 取脚本 → 在“X”上执行（本地生成密钥 + 交 CSR）→ 校验证书 → 券作废
set -uo pipefail

STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE="http://127.0.0.1:18443"
OP="authorization: Bearer ${DEV_PASSWORD:-dev-only-password}"
WORK=/tmp/wist-e2e

rm -rf "$WORK"
mkdir -p "$WORK"

echo "── ① 签发接入券 ────────────────────────────────────────────"
path=$(curl -fsS -X POST "$BASE/api/v1/peers/wist-ingest/enrollment-tickets" -H "$OP" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["path"])')
echo "  path = $path"
token=${path#/enroll/}
token=${token%/join.sh}

echo "── ② 取脚本 ────────────────────────────────────────────────"
curl -fsSL "$BASE$path" -o "$WORK/join.sh"
if rg -q 'PRIVATE KEY' "$WORK/join.sh"; then
  echo "  ✗ 脚本里有私钥！" >&2; exit 1
fi
echo "  脚本 $(wc -c <"$WORK/join.sh") 字节，无任何私钥 ✓"

echo "── ③ 在 X 上执行（本地生成密钥，只上交 CSR）────────────────"
# 不需要 root：材料目录用 --dir 指到工作目录（脚本只看目录可不可写）。
bash "$WORK/join.sh" --dir "$WORK/install" 2>&1 | sed 's/^/  /'
echo "  exit=$?"

echo "── ④ 校验材料 ──────────────────────────────────────────────"
ls -l "$WORK/install"
CA="$STACK/dev/identity/ca-s.crt"
echo -n "  链校验（CA-S）: "; openssl verify -CAfile "$CA" "$WORK/install/server.crt"
echo -n "  SAN: "; openssl x509 -in "$WORK/install/server.crt" -noout -ext subjectAltName | sed -n '2,$p' | tr -d ' '
echo -n "  证书公钥 == 私钥公钥: "
a=$(openssl x509 -in "$WORK/install/server.crt" -noout -pubkey | openssl sha256)
b=$(openssl pkey -in "$WORK/install/server.key" -pubout | openssl sha256)
[ "$a" = "$b" ] && echo "是 ✓" || echo "否 ✗"

echo "── ⑤ 券应该已经作废 ────────────────────────────────────────"
code=$(curl -s -o /tmp/wist-e2e-replay.json -w '%{http_code}' -X POST "$BASE/enroll/$token/certificate" \
  -H 'content-type: application/json' -H 'accept: application/x-pem-file' \
  --data-binary "{\"certificate_signing_request\":\"$(cat "$WORK/install/server.csr" | awk '{gsub(/\\/,"\\\\");gsub(/"/,"\\\"");printf "%s\\n",$0}')\"}")
echo "  重放 HTTP $code （期望 401）"
cat /tmp/wist-e2e-replay.json | sed 's/^/    /'

echo "── ⑥ 取脚本也应失效 ────────────────────────────────────────"
code=$(curl -s -o /dev/null -w '%{http_code}' "$BASE$path")
echo "  HTTP $code （期望 410）"
