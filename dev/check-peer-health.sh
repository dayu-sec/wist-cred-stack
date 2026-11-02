#!/usr/bin/env bash
# 端到端验证「建认证系统 → 心跳发现可联通 → 推送」。
#
# 流程：
#   1. 通过 API 新建一个认证系统（不等配置、不等重启）
#   2. 用它的接入命令在本地生成密钥 + 拿证书（模拟 X）
#   3. 用这张证书起一个 mTLS 的 /healthz
#   4. 等一轮心跳，确认页面/API 能看到 up
#
# 用法：dev/check-peer-health.sh
set -uo pipefail

STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE="http://127.0.0.1:18443"
OP="x-wist-operator: dev"
PEER="probe-local"
PORT="${PROBE_PORT:-19455}"
WORK=/tmp/wist-peer-health
SAND=/tmp/wist-peer-sandbox

rm -rf "$WORK" "$SAND"; mkdir -p "$WORK" "$SAND/bin"
printf '#!/bin/sh\n[ "$1" = "-u" ] && { echo 0; exit 0; }\n/usr/bin/id "$@"\n' >"$SAND/bin/id"
chmod +x "$SAND/bin/id"

cleanup() { [[ -n "${SRV:-}" ]] && kill -9 "${SRV}" 2>/dev/null; }
trap cleanup EXIT

echo "── ① 通过 API 新建认证系统 ─────────────────────────────────"
code=$(curl -s -o "$WORK/created.json" -w '%{http_code}' -X POST "$BASE/api/v1/onboarding/peers" \
  -H "$OP" -H 'content-type: application/json' \
  -d "{\"name\":\"$PEER\",\"host\":\"localhost\",\"endpoint\":\"https://localhost:$PORT/api/v1/internal/credentials\"}")
echo "  HTTP $code"
if [[ "$code" != "201" ]]; then
  cat "$WORK/created.json" | sed 's/^/  /'
  [[ "$code" == "409" ]] || exit 1
  echo "  （已存在，继续）"
fi

echo "── ② 生成接入命令并在“X”上执行 ────────────────────────────"
path=$(curl -fsS -X POST "$BASE/api/v1/onboarding/peers/$PEER/script" -H "$OP" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["path"])')
curl -fsSL "$BASE$path" -o "$WORK/join.sh"
rg -q 'PRIVATE KEY' "$WORK/join.sh" && { echo "  ✗ 脚本里有私钥" >&2; exit 1; }
PATH="$SAND/bin:$PATH" bash "$WORK/join.sh" --dir "$WORK/install" 2>&1 | rg '✓|✗' | sed 's/^/  /'

echo "── ③ 起一个 mTLS 的 /healthz（要求客户端证书）─────────────"
openssl s_server -accept "$PORT" \
  -cert "$WORK/install/server.crt" -key "$WORK/install/server.key" \
  -CAfile "$WORK/install/client-ca.pem" -Verify 1 -verify_return_error -www \
  >"$WORK/server.log" 2>&1 &
SRV=$!
sleep 1.5

echo "  cred 直连探一次（与心跳同一套 mTLS）:"
curl -sS --max-time 5 \
  --cert "$STACK/dev/identity/cred-client.crt" --key "$STACK/dev/identity/cred-client.key" \
  --cacert "$STACK/dev/identity/ca-s.crt" \
  -o /dev/null -w '    HTTP %{http_code}\n' "https://localhost:$PORT/healthz" || echo "    探测失败"

echo "── ④ 等一轮心跳（最长 40s）────────────────────────────────"
hb=$(curl -fsS "$BASE/api/v1/onboarding/peers" -H "$OP" | python3 -c 'import sys,json;print(int(json.load(sys.stdin)["heartbeat_seconds"] or 30))')
deadline=$(( SECONDS + hb + 10 ))
state=""
while [[ $SECONDS -lt $deadline ]]; do
  state=$(curl -fsS "$BASE/api/v1/onboarding/peers" -H "$OP" \
    | python3 -c "import sys,json;print([p['health'] for p in json.load(sys.stdin)['peers'] if p['name']=='$PEER'][0])")
  [[ "$state" == "up" ]] && break
  sleep 2
done
echo "  最终状态：$state"
curl -fsS "$BASE/api/v1/onboarding/peers" -H "$OP" \
  | python3 -c "import sys,json;d=[p for p in json.load(sys.stdin)['peers'] if p['name']=='$PEER'][0];print('  ', json.dumps(d, ensure_ascii=False))"

[[ "$state" == "up" ]] || { echo "✗ 心跳没能识别为 up" >&2; exit 1; }
echo
echo "✓ 建系统 → 发证书 → 心跳识别为可联通"
