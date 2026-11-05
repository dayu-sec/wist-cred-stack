#!/usr/bin/env bash
# 开发态统一入口：本地起 / 停 / 看 cred 与 web，外加一条龙验证。
#
# 组件（不给 = 默认 cred + web；`all` = 三个都给）：
#   cred   凭据服务后端（cargo run，默认 http://127.0.0.1:18443）
#   web    管理页面（vite dev，默认 http://127.0.0.1:5174，/api 反代到 cred 并注入操作者头）
#   peer   示例验证方（wist-cred 仓 examples/peer_example.rs，用已发布的 wist-cred-peer，https://localhost:19455）
#
# 用法：
#   ./dev/svc.sh start   [组件…] [--no-build]   默认 cred web
#   ./dev/svc.sh stop    [组件…]                默认全部
#   ./dev/svc.sh restart [组件…] [--no-build]   停所选（逆序）再起回（正序）
#   ./dev/svc.sh status
#   ./dev/svc.sh logs    [cred|web|peer] [-f]
#   ./dev/svc.sh token   [选项]                 创建一条凭据并打印明文（只此一次）
#   ./dev/svc.sh verify  <token> [--audience wist-center]
#   ./dev/svc.sh demo                           签发 → 验证 → 撤销 → 再验证
#   ./dev/svc.sh onboard [peer]               生成接入链接，打印 `curl … | bash`（默认 wist-ingest）
#   ./dev/svc.sh peer-check                   对示例验证方跑一次「签发 → 验证 → 撤销 → 再验证」
#
# 例：
#   ./dev/svc.sh start                 # 后端 + 页面
#   ./dev/svc.sh start web             # 只起页面（cred 得已经在跑）
#   ./dev/svc.sh restart cred          # 改了 Rust 代码后重启后端
#   ./dev/svc.sh logs web -f
#
# token 选项：
#   --subject <name>     程序名（默认 dev-script）
#   --roles a,b          默认 investigation:run
#   --audience <svc>     默认 wist-center
#   --ttl <seconds>      不传则用上限
#   --break-glass        用 break-glass 上限
#   --purpose <text>     默认 "dev"
#
# 可覆盖 env：
#   WIST_CRED_SRC     后端仓（默认 ../../wist/wist-cred）
#   WIST_CRED_WEB_SRC 页面仓（默认 ../../wist/wist-cred-web）
#   WIST_AUTH_SRC     验证库（默认 ../../wist/wist-auth）
#   DEV_ADDR          后端监听（默认 127.0.0.1:18443）
#   WEB_PORT          页面端口（默认 5174）
#   DEV_OPERATOR      操作者名（默认 dev）
#
# 关于身份：dev 里 cred 跑 `mode = "ingress"`，`x-wist-operator` 由 vite 代理注入 ——
# 开发时不用每次输口令。**发布态不是这么做的**：`mode = "token"`，页面有登录框，
# 口令带在 `Authorization: Bearer` 上，由 cred 自己验。
#
# 注：dev 循环直接用 cargo build / vite（跳过 gx 的版本同步 + 全量测试）；
#     提交 / 发版前仍以 `gx run lint` / `gx run build` 为准。
set -euo pipefail

STACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="${STACK_ROOT}/../.."

CRED_SRC="${WIST_CRED_SRC:-${ROOT}/wist/wist-cred}"
WEB_SRC="${WIST_CRED_WEB_SRC:-${ROOT}/wist/wist-cred-web}"
AUTH_SRC="${WIST_AUTH_SRC:-${ROOT}/wist/wist-auth}"

DEV_DIR="${STACK_ROOT}/dev"
CONF_DIR="${DEV_DIR}/configs"
STATE_DIR="${CONF_DIR}/state"
PKI_DIR="${DEV_DIR}/identity"
CONF="${CONF_DIR}/cred.toml"
RUN_DIR="${DEV_DIR}/.run"
CRED_PID_FILE="${RUN_DIR}/cred.pid"
CRED_LOG="${RUN_DIR}/cred.log"
WEB_PID_FILE="${RUN_DIR}/web.pid"
WEB_LOG="${RUN_DIR}/web.log"
CRED_BIN="${CRED_SRC}/target/debug/wist-cred"
WEB_BIN="${WEB_SRC}/node_modules/.bin/vite"

# 示例验证方：**跟着 wist-cred 仓走**（`examples/peer_example.rs`，依赖已发布的 wist-cred-peer），
# 发布时同一个镜像里就有这个二进制（`wist-cred-example`）。dev 态直接 cargo 起。
PEER_BIN="${CRED_SRC}/target/debug/examples/peer_example"
PEER_PID_FILE="${RUN_DIR}/peer.pid"
PEER_LOG="${RUN_DIR}/peer.log"
PEER_DIR="${RUN_DIR}/peer"
PEER_STORE="${PEER_DIR}/state.json"
PEER_NAME="${DEV_PEER_NAME:-peer-demo}"
PEER_PORT="${DEV_PEER_PORT:-19455}"
PEER_ROLES="${DEV_PEER_ROLES:-read,investigation:run}"
PEER_BASE="/api/v1/internal/credentials"
PEER_URL="https://localhost:${PEER_PORT}"

ADDR="${DEV_ADDR:-127.0.0.1:18443}"
WEB_PORT="${WEB_PORT:-5174}"
OPERATOR="${DEV_OPERATOR:-dev}"
BASE_URL="http://${ADDR}"
WEB_URL="http://127.0.0.1:${WEB_PORT}"

ALL_COMPONENTS=(cred web peer)
# `start` 不给组件时只起这两个：peer 需要先建系统、走一次接入，不适合当默认。
DEFAULT_COMPONENTS=(cred web)

usage() {
  awk 'NR>=2 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
}

die() {
  echo "错误：$*" >&2
  exit 1
}

note() { echo "  $*"; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1"
}

# ── 通用 ────────────────────────────────────────────────────────────────────

read_pid() {
  local file="$1" pid
  [[ -f "${file}" ]] || return 1
  pid="$(cat "${file}" 2>/dev/null || true)"
  [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null && echo "${pid}"
}

wait_for() {
  local url="$1" tries="${2:-50}"
  local i
  for i in $(seq 1 "${tries}"); do
    curl -fsS --max-time 1 "${url}" >/dev/null 2>&1 && return 0
    sleep 0.1
  done
  return 1
}

# ── cred ────────────────────────────────────────────────────────────────────

cred_pid() { read_pid "${CRED_PID_FILE}"; }
cred_healthy() { curl -fsS --max-time 1 "${BASE_URL}/healthz" >/dev/null 2>&1; }

# 双向认证用的 PKI + 接入包（dev 也走真证书，不提供 mock）。
# 幂等：已有的 CA / 证书不会被重签。
ensure_pki() {
  local peers="${DEV_PKI_PEERS:-wist-ingest=ingest.internal}"
  "${STACK_ROOT}/scripts/gen-pki.sh" "${PKI_DIR}" ${peers} >/dev/null
  note "PKI/接入包就绪：${PKI_DIR}/onboarding"
}

write_cred_config() {
  mkdir -p "${CONF_DIR}" "${STATE_DIR}" "${RUN_DIR}"
  local tmp="${CONF}.tmp.$$"
  cat >"${tmp}" <<EOF
# 由 dev/svc.sh 生成，改它没用（下次 start 会覆盖）。要改就改脚本里的默认值或 env。
[server]
listen_addr = "${ADDR}"
mode = "ingress"
ingress_header = "x-wist-operator"
trusted_peers = ["127.0.0.1/32"]

[storage]
path = "${STATE_DIR}/credentials.db"

[issue]
digest = "sha256"
max_ttl_seconds = 2592000
break_glass_max_ttl_seconds = 7776000
overlap_seconds = 300
# 授权记录签名钥（Ed25519）：没有它也能签发，但验证方开了 require_signature 会拒收。
signing_key = "${PKI_DIR}/signing.key"

[push]
client_cert = "${PKI_DIR}/cred-client.crt"
client_key = "${PKI_DIR}/cred-client.key"
ca = "${PKI_DIR}/ca-s.crt"
timeout_seconds = 5

[onboarding]
dir = "${PKI_DIR}/onboarding"
store_path = "${STATE_DIR}/peers.json"
script_ttl_seconds = 900
ca_cert = "${PKI_DIR}/ca-s.crt"
ca_key = "${PKI_DIR}/ca-s.key"
client_ca = "${PKI_DIR}/ca-i.crt"
peer_cert_ttl_seconds = 7776000
heartbeat_seconds = 30
EOF
  if [[ -f "${CONF}" ]] && cmp -s "${tmp}" "${CONF}"; then
    rm -f "${tmp}"
  else
    mv -f "${tmp}" "${CONF}"
    note "已写 dev 配置：${CONF}"
  fi
}

start_cred() {
  local do_build="$1"
  local pid
  if pid="$(cred_pid)"; then
    note "cred 已在运行（pid ${pid}，${BASE_URL}），复用。"
    return 0
  fi

  require_cmd curl
  ensure_pki
  write_cred_config

  if [[ "${do_build}" == "1" ]]; then
    [[ -d "${CRED_SRC}" ]] || die "找不到后端仓：${CRED_SRC}（用 WIST_CRED_SRC 指定）"
    note "构建 ${CRED_SRC} …"
    (cd "${CRED_SRC}" && cargo build --quiet)
  fi
  [[ -x "${CRED_BIN}" ]] || die "没有二进制：${CRED_BIN}（先不带 --no-build 跑一次）"

  note "启动 cred：${CRED_BIN}"
  # 部署栈版本：发布态由 compose 把 version.txt 挂进容器；dev 直接读栈根的 version.txt，
  # 页面右上角「wist-cred-stack」那一行才有值（读不到就显示 `—`）。
  WIST_CRED_STACK_VERSION="$(cat "${STACK_ROOT}/version.txt" 2>/dev/null || true)" \
    nohup "${CRED_BIN}" "${CONF}" >"${CRED_LOG}" 2>&1 &
  echo $! >"${CRED_PID_FILE}"

  if wait_for "${BASE_URL}/healthz"; then
    note "cred 就绪：${BASE_URL}"
  else
    echo "cred 启动失败，日志尾部：" >&2
    tail -n 20 "${CRED_LOG}" >&2 || true
    rm -f "${CRED_PID_FILE}"
    exit 1
  fi
}

stop_cred() {
  local pid
  if ! pid="$(cred_pid)"; then
    note "cred 没在跑。"
    rm -f "${CRED_PID_FILE}"
    return 0
  fi
  note "停止 cred（pid ${pid}）"
  kill "${pid}" 2>/dev/null || true
  local i
  for i in $(seq 1 30); do
    kill -0 "${pid}" 2>/dev/null || break
    sleep 0.1
  done
  kill -0 "${pid}" 2>/dev/null && kill -9 "${pid}" 2>/dev/null || true
  rm -f "${CRED_PID_FILE}"
}

# ── web ─────────────────────────────────────────────────────────────────────

web_pid() { read_pid "${WEB_PID_FILE}"; }
web_healthy() { curl -fsS --max-time 1 "${WEB_URL}/" >/dev/null 2>&1; }

start_web() {
  local pid
  if pid="$(web_pid)"; then
    note "web 已在运行（pid ${pid}，${WEB_URL}），复用。"
    return 0
  fi

  require_cmd curl
  require_cmd node
  [[ -d "${WEB_SRC}" ]] || die "找不到页面仓：${WEB_SRC}（用 WIST_CRED_WEB_SRC 指定）"

  mkdir -p "${RUN_DIR}"
  if [[ ! -x "${WEB_BIN}" ]]; then
    require_cmd npm
    note "安装页面依赖（首次会慢）：${WEB_SRC}"
    (cd "${WEB_SRC}" && npm install --silent)
  fi

  # 直接跑 vite 的 bin：pid 就是 vite 本身，stop 时不会留下孤儿 node。
  note "启动 web：${WEB_BIN}（/api → ${BASE_URL}，操作者 ${OPERATOR}）"
  (
    cd "${WEB_SRC}"
    WIST_CRED_TARGET="${BASE_URL}" \
      WIST_OPERATOR="${OPERATOR}" \
      WIST_CRED_WEB_PORT="${WEB_PORT}" \
      nohup "${WEB_BIN}" >"${WEB_LOG}" 2>&1 &
    echo $! >"${WEB_PID_FILE}"
  )

  if wait_for "${WEB_URL}/" 80; then
    note "web 就绪：${WEB_URL}"
  else
    echo "web 启动失败，日志尾部：" >&2
    tail -n 20 "${WEB_LOG}" >&2 || true
    rm -f "${WEB_PID_FILE}"
    exit 1
  fi
}

stop_web() {
  local pid
  if ! pid="$(web_pid)"; then
    note "web 没在跑。"
    rm -f "${WEB_PID_FILE}"
    return 0
  fi
  note "停止 web（pid ${pid}）"
  kill "${pid}" 2>/dev/null || true
  local i
  for i in $(seq 1 30); do
    kill -0 "${pid}" 2>/dev/null || break
    sleep 0.1
  done
  kill -0 "${pid}" 2>/dev/null && kill -9 "${pid}" 2>/dev/null || true
  rm -f "${WEB_PID_FILE}"
}

# ── peer（示例验证方）──────────────────────────────────────────────────────

peer_pid() { read_pid "${PEER_PID_FILE}"; }

# 用 cred 自己的客户端证书去探 —— 与心跳同一套 mTLS。
peer_healthy() {
  [[ -f "${PKI_DIR}/cred-client.crt" ]] || return 1
  curl -fsS --max-time 2 \
    --cert "${PKI_DIR}/cred-client.crt" --key "${PKI_DIR}/cred-client.key" \
    --cacert "${PKI_DIR}/ca-s.crt" \
    "${PEER_URL}/healthz" >/dev/null 2>&1
}

# 在 cred 里建好这个演示系统，并用**真实的一次性接入命令**把证书换到本机。
ensure_demo_peer() {
  local code path sand
  code="$(curl -s -o /dev/null -w '%{http_code}' -X POST "${BASE_URL}/api/v1/peers" \
    -H "x-wist-operator: ${OPERATOR}" -H 'content-type: application/json' \
    -d "{\"name\":\"${PEER_NAME}\",\"host\":\"localhost\"}")"
  [[ "${code}" == "201" || "${code}" == "409" ]] \
    || die "建认证系统 ${PEER_NAME} 失败（HTTP ${code}）"

  [[ -f "${PEER_DIR}/install/server.crt" ]] && return 0

  note "为 ${PEER_NAME} 走一次接入命令（本机生成密钥，cred 按 CSR 签）…"
  sand="${RUN_DIR}/peer-sandbox"
  mkdir -p "${sand}" "${PEER_DIR}/install"

  path="$(curl -fsS -X POST "${BASE_URL}/api/v1/peers/${PEER_NAME}/enrollment-tickets" \
    -H "x-wist-operator: ${OPERATOR}" \
    | python3 -c 'import sys,json;print(json.load(sys.stdin)["path"])')"
  curl -fsSL "${BASE_URL}${path}" -o "${sand}/join.sh"
  bash "${sand}/join.sh" \
    --dir "${PEER_DIR}/install" \
    --host localhost \
    --advertise "${PEER_URL}${PEER_BASE}" \
    --roles "${PEER_ROLES}" >/dev/null
}

start_peer() {
  local do_build="$1" pid i
  if pid="$(peer_pid)"; then
    note "peer 已在运行（pid ${pid}，${PEER_URL}），复用。"
    return 0
  fi

  require_cmd curl
  cred_healthy || die "cred 没在跑，先 ./dev/svc.sh start cred"
  [[ -d "${CRED_SRC}" ]] || die "找不到 cred 源码：${CRED_SRC}（示例验证方在它的 examples/ 里）"

  ensure_demo_peer

  if [[ "${do_build}" == "1" ]]; then
    note "构建 ${CRED_SRC} 的示例 peer_example …"
    (cd "${CRED_SRC}" && cargo build --quiet --example peer_example)
  fi
  [[ -x "${PEER_BIN}" ]] || die "没有二进制：${PEER_BIN}（先不带 --no-build 跑一次）"

  mkdir -p "${PEER_DIR}"
  note "启动 peer：${PEER_BIN}"
  local peer_args=(
    --listen "127.0.0.1:${PEER_PORT}"
    --dir "${PEER_DIR}/install"
    --store "${PEER_STORE}"
    --audience "${PEER_NAME}"
    --issuer wist-cred
    --known-roles "${PEER_ROLES}"
    --verify-endpoint
  )
  # 接入脚本会落下 `issuer-signing.pub`；有它就开验签（旧接入包没有，先不卡）。
  if [[ -f "${PEER_DIR}/install/issuer-signing.pub" ]]; then
    peer_args+=(--issuer-public-key-file "${PEER_DIR}/install/issuer-signing.pub")
  else
    note "未找到 issuer-signing.pub：peer 不验授权记录签名（重跑接入命令可补）"
  fi
  nohup "${PEER_BIN}" "${peer_args[@]}" >"${PEER_LOG}" 2>&1 &
  echo $! >"${PEER_PID_FILE}"

  for i in $(seq 1 50); do
    if peer_healthy; then
      note "peer 就绪：${PEER_URL}（audience=${PEER_NAME}）"
      return 0
    fi
    sleep 0.1
  done
  echo "peer 启动失败，日志尾部：" >&2
  tail -n 20 "${PEER_LOG}" >&2 || true
  rm -f "${PEER_PID_FILE}"
  exit 1
}

stop_peer() {
  local pid i
  if ! pid="$(peer_pid)"; then
    note "peer 没在跑。"
    rm -f "${PEER_PID_FILE}"
    return 0
  fi
  note "停止 peer（pid ${pid}）"
  kill "${pid}" 2>/dev/null || true
  for i in $(seq 1 30); do
    kill -0 "${pid}" 2>/dev/null || break
    sleep 0.1
  done
  kill -0 "${pid}" 2>/dev/null && kill -9 "${pid}" 2>/dev/null || true
  rm -f "${PEER_PID_FILE}"
}

# ── 组件调度 ────────────────────────────────────────────────────────────────

normalize_components() {
  local given=("$@")
  if [[ ${#given[@]} -eq 0 ]]; then
    printf '%s\n' "${DEFAULT_COMPONENTS[@]}"
    return
  fi
  local item out=()
  for item in "${given[@]}"; do
    if [[ "${item}" == "all" ]]; then
      out+=("${ALL_COMPONENTS[@]}")
      continue
    fi
    local known=0 candidate
    for candidate in "${ALL_COMPONENTS[@]}"; do
      [[ "${candidate}" == "${item}" ]] && known=1
    done
    [[ "${known}" == "1" ]] || die "未知组件：${item}（可选：${ALL_COMPONENTS[*]} / all）"
    out+=("${item}")
  done
  printf '%s\n' "${out[@]}" | awk '!seen[$0]++'
}

# 读组件列表到 chosen（不依赖 bash 4 的 mapfile）。
collect_components() {
  chosen=()
  local line
  while IFS= read -r line; do
    if [[ -n "${line}" ]]; then
      chosen+=("${line}")
    fi
  done < <(normalize_components ${@+"$@"})
}

# ── 子命令 ──────────────────────────────────────────────────────────────────

cmd_start() {
  local do_build=1 components=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --no-build) do_build=0; shift ;;
      --*) die "未知选项：$1" ;;
      *) components+=("$1"); shift ;;
    esac
  done
  collect_components ${components[@]+"${components[@]}"}

  local component
  for component in "${chosen[@]}"; do
    case "${component}" in
      cred) start_cred "${do_build}" ;;
      web) start_web ;;
      peer) start_peer "${do_build}" ;;
    esac
  done

  echo
  echo "  页面：${WEB_URL}"
  echo "  API ：${BASE_URL}"
  echo
  echo "  ⚠ cred 只有 API，没有页面；页面在 ${WEB_URL}（vite dev）。"
  echo "    浏览器直接打开 ${BASE_URL}/ 只会看到一份自述 JSON，不是 UI。"
  echo
  echo "  GET  ${BASE_URL}/healthz"
  echo "  GET  ${BASE_URL}/api/v1/credentials  -H 'x-wist-operator: ${OPERATOR}'   # 缺这个头会 401"
  echo "  POST ${BASE_URL}/api/v1/credentials   → 用 ./dev/svc.sh token"
  local has_peer=0
  for component in "${chosen[@]}"; do
    [[ "${component}" == "peer" ]] && has_peer=1
  done
  if [[ "${has_peer}" == "1" ]]; then
    echo
    echo "  示例验证方：${PEER_URL}（audience=${PEER_NAME}）"
    echo "    register  POST ${PEER_URL}${PEER_BASE}"
    echo "    health    GET  ${PEER_URL}/healthz"
    echo "    verify    POST ${PEER_URL}/verify   {\"token\":\"wcr_…\"}   # 仅联调"
    echo "    签发时用 --audience ${PEER_NAME}，凭据会直接推到这里"
  fi
  echo
  echo "  日志：${CRED_LOG}   ${WEB_LOG}   ${PEER_LOG}"
}

cmd_stop() {
  local components=(${@+"$@"})
  if [[ ${#components[@]} -eq 0 ]]; then
    components=("${ALL_COMPONENTS[@]}")
  fi
  collect_components ${components[@]+"${components[@]}"}

  # 逆序停：web 先，cred 后。
  local i component
  for (( i=${#chosen[@]}-1; i>=0; i-- )); do
    component="${chosen[i]}"
    case "${component}" in
      cred) stop_cred ;;
      web) stop_web ;;
      peer) stop_peer ;;
    esac
  done
}

cmd_status() {
  local pid

  pid="$(cred_pid || true)"
  echo "cred   : $( [[ -n "${pid}" ]] && echo "running (pid ${pid})" || echo stopped )"
  echo "  addr : ${BASE_URL}"
  echo "  conf : ${CONF}"
  echo "  store: ${STATE_DIR}/credentials.db"
  if cred_healthy; then
    echo "  health: ok"
    if command -v jq >/dev/null 2>&1; then
      echo "  entries: $(curl -fsS "${BASE_URL}/api/v1/credentials" \
        -H "x-wist-operator: ${OPERATOR}" | jq '.credentials | length')"
      echo "  peers  : $(curl -fsS "${BASE_URL}/api/v1/peers" \
        -H "x-wist-operator: ${OPERATOR}" | jq -r '[.peers[].name] | join(", ")')"
    fi
  else
    echo "  health: 不可达"
  fi

  pid="$(web_pid || true)"
  echo "web    : $( [[ -n "${pid}" ]] && echo "running (pid ${pid})" || echo stopped )"
  echo "  url  : ${WEB_URL}"
  echo "  log  : ${WEB_LOG}"
  if web_healthy; then
    echo "  health: ok"
  else
    echo "  health: 不可达"
  fi

  pid="$(peer_pid || true)"
  echo "peer   : $( [[ -n "${pid}" ]] && echo "running (pid ${pid})" || echo stopped )"
  echo "  url  : ${PEER_URL}（audience=${PEER_NAME}）"
  echo "  store: ${PEER_STORE}"
  if peer_healthy; then
    echo "  health: ok"
  else
    echo "  health: 不可达"
  fi
}

cmd_logs() {
  local target="cred"
  local follow=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      cred | web | peer) target="$1"; shift ;;
      -f) follow=1; shift ;;
      *) die "未知参数：$1" ;;
    esac
  done
  local file="${CRED_LOG}"
  [[ "${target}" == "web" ]] && file="${WEB_LOG}"
  [[ "${target}" == "peer" ]] && file="${PEER_LOG}"
  [[ -f "${file}" ]] || die "还没有日志：${file}"
  if [[ "${follow}" == "1" ]]; then
    tail -f "${file}"
  else
    tail -n 50 "${file}"
  fi
}

cmd_token() {
  require_cmd curl
  require_cmd jq
  cred_healthy || die "cred 没在跑，先 ./dev/svc.sh start cred"

  local subject="dev-script" roles="investigation:run" audience="wist-center"
  local ttl="" break_glass="false" purpose="dev"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --subject) subject="$2"; shift 2 ;;
      --roles) roles="$2"; shift 2 ;;
      --audience) audience="$2"; shift 2 ;;
      --ttl) ttl="$2"; shift 2 ;;
      --purpose) purpose="$2"; shift 2 ;;
      --break-glass) break_glass="true"; shift ;;
      *) die "未知选项：$1" ;;
    esac
  done

  local body
  body="$(jq -n \
    --arg subject "${subject}" \
    --arg purpose "${purpose}" \
    --arg audience "${audience}" \
    --arg roles "${roles}" \
    --argjson break_glass "${break_glass}" \
    --arg ttl "${ttl}" \
    '{
       subject: $subject,
       purpose: $purpose,
       audience: $audience,
       roles: ($roles | split(",") | map(select(length > 0))),
       resources: {},
       break_glass: $break_glass
     }
     + (if $ttl == "" then {} else { ttl_seconds: ($ttl | tonumber) } end)')"

  local response
  response="$(curl -fsS -X POST "${BASE_URL}/api/v1/credentials" \
    -H "x-wist-operator: ${OPERATOR}" \
    -H 'content-type: application/json' \
    -d "${body}")" || die "创建失败（cred 在跑吗？）"

  echo "$response" | jq -r '"credential_id: \(.credential_id)\nsubject:       \(.subject)\nroles:         \(.roles | join(","))\naudience:      \(.audience)\nexpires_at:    \(.expires_at)\ntoken:         \(.token)\n\n# 明文只出现这一次；验一下：\n./dev/svc.sh verify \(.token) --audience \(.audience)"'
}

cmd_verify() {
  local token="${1:-}"
  [[ -n "${token}" ]] || die "用法：./dev/svc.sh verify <token> [--audience <svc>]"
  shift || true

  local audience="wist-center"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --audience) audience="$2"; shift 2 ;;
      *) die "未知选项：$1" ;;
    esac
  done

  [[ -d "${AUTH_SRC}" ]] || die "找不到 wist-auth：${AUTH_SRC}（用 WIST_AUTH_SRC 指定）"
  (cd "${AUTH_SRC}" && cargo run --quiet --features credential --example verify_credential -- \
    --store "${STATE_DIR}/credentials.db" \
    --token "${token}" \
    --audience "${audience}")
}

# 生成一次性接入链接并打印可直接粘贴的一行命令。
cmd_onboard() {
  require_cmd curl
  require_cmd jq
  cred_healthy || die "cred 没在跑，先 ./dev/svc.sh start cred"

  local peer="${1:-wist-ingest}"
  local minted path ttl
  minted="$(curl -fsS -X POST "${BASE_URL}/api/v1/peers/${peer}/enrollment-tickets" \
    -H "x-wist-operator: ${OPERATOR}")" || die "签发接入链接失败（peer 存在吗？）"
  path="$(echo "${minted}" | jq -r .path)"
  ttl="$(echo "${minted}" | jq -r .expires_in)"

  echo "接入命令（券 ${ttl}s 内有效，登记时作废）："
  echo
  echo "  curl -fsSLk ${BASE_URL}${path} | bash"
  echo
  echo "  只落材料不改配置：  ... | bash"
  echo "  顺带写进配置：      ... | bash -s -- --config /etc/x/ctrl.toml"
  echo "  并重启：            ... | bash -s -- --config /etc/x/ctrl.toml --restart 'systemctl restart x-ctrl'"
  echo
  echo "X 在本机生成密钥（永不上送），只交 CSR；证书由 CA-S 按 CSR 签。"
  echo "材料落点：root 默认 /etc/wist/${peer}，普通用户默认 ./wist-cred/${peer}（可用 --dir 改）。"
}

cmd_demo() {
  require_cmd curl
  require_cmd jq
  cred_healthy || die "cred 没在跑，先 ./dev/svc.sh start cred"

  local created token id audience peer roles
  # 受众与角色都从注册表里取：写死的名字在接入别的系统后就失效了。
  peer="$(curl -fsS "${BASE_URL}/api/v1/peers" -H "x-wist-operator: ${OPERATOR}" \
    | jq -r '.peers[0].name // empty')"
  [[ -n "${peer}" ]] || die "还没有认证系统，先 ./dev/svc.sh onboard 接入一个"
  roles="$(curl -fsS "${BASE_URL}/api/v1/peers" -H "x-wist-operator: ${OPERATOR}" \
    | jq -r '.peers[0].roles // [] | join(",")')"
  [[ -n "${roles}" ]] || die "${peer} 还没登记角色；接入时带 --roles a,b,c"

  created="$(curl -fsS -X POST "${BASE_URL}/api/v1/credentials" \
    -H "x-wist-operator: ${OPERATOR}" \
    -H 'content-type: application/json' \
    -d "$(jq -nc --arg audience "${peer}" --arg roles "${roles}" \
      '{subject:"ci-nightly",purpose:"dev demo",roles:($roles | split(",")),resources:{agents:["agent-7f3"]},audience:$audience}')")"
  token="$(echo "$created" | jq -r .token)"
  id="$(echo "$created" | jq -r .credential_id)"
  audience="$(echo "$created" | jq -r .audience)"

  echo "① 签发        ${id}"
  echo "② 验证（应通过）"
  cmd_verify "${token}" --audience "${audience}" || true

  echo "③ 撤销"
  curl -fsS -X POST "${BASE_URL}/api/v1/credentials/${id}/revoke" \
    -H "x-wist-operator: ${OPERATOR}" | jq -r '"   revision=\(.revision) revoked_at=\(.revoked_at)"'

  echo "④ 再验证（应失败 token_revoked）"
  cmd_verify "${token}" --audience "${audience}" || true

  echo
  echo "闭环成立。"
}

cmd_restart() {
  local do_build=0 comps=()
  local arg
  for arg in ${@+"$@"}; do
    if [[ "${arg}" == "--no-build" ]]; then
      do_build=1
    else
      comps+=("${arg}")
    fi
  done

  local start_args
  start_args=(${comps[@]+"${comps[@]}"})
  if [[ "${do_build}" == "1" ]]; then
    start_args+=(--no-build)
  fi

  cmd_stop ${comps[@]+"${comps[@]}"}
  cmd_start ${start_args[@]+"${start_args[@]}"}
}

# 用 cred 自己的客户端证书去问 peer（与推送同一套 mTLS）。
peer_verify() {
  curl -sS --cert "${PKI_DIR}/cred-client.crt" --key "${PKI_DIR}/cred-client.key" \
    --cacert "${PKI_DIR}/ca-s.crt" \
    -X POST "${PEER_URL}/verify" -H 'content-type: application/json' \
    -d "{\"token\":\"$1\"}" \
    | python3 -c 'import sys,json;d=json.load(sys.stdin);print("ok" if d.get("ok") else d.get("code"))'
}

# 一条命令跑完「签发 → 推送 → 本地验证 → 撤销 → 再验证」。
cmd_peer_check() {
  require_cmd curl
  require_cmd python3
  peer_healthy || die "peer 没在跑：./dev/svc.sh start peer"

  local role="${PEER_ROLES%%,*}" created token id
  created="$(curl -fsS -X POST "${BASE_URL}/api/v1/credentials" \
    -H "x-wist-operator: ${OPERATOR}" -H 'content-type: application/json' \
    -d "$(python3 -c 'import json,sys;print(json.dumps({"purpose":"peer-check","roles":[sys.argv[1]],"audience":sys.argv[2]}))' "${role}" "${PEER_NAME}")")"
  token="$(printf '%s' "${created}" | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')"
  id="$(printf '%s' "${created}" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credential_id"])')"

  echo "① 签发 ${id}（audience=${PEER_NAME}，role=${role}）—— 摘要已推给 peer"
  echo "② peer /verify             $(peer_verify "${token}")"

  curl -s -o /dev/null -X POST "${BASE_URL}/api/v1/credentials/${id}/revoke" \
    -H "x-wist-operator: ${OPERATOR}"
  echo "③ cred 撤销后再 /verify     $(peer_verify "${token}")"
  echo
  echo "闭环成立：推送 → 本地验证 → 撤销即刻生效。"
}

# ── 入口 ────────────────────────────────────────────────────────────────────

cmd="${1:-}"
shift || true

case "${cmd}" in
  start) cmd_start "$@" ;;
  stop) cmd_stop "$@" ;;
  restart) cmd_restart "$@" ;;
  status) cmd_status ;;
  logs) cmd_logs "$@" ;;
  token) cmd_token "$@" ;;
  verify) cmd_verify "$@" ;;
  demo) cmd_demo ;;
  onboard) cmd_onboard "$@" ;;
  peer-check) cmd_peer_check ;;
  "" | -h | --help | help) usage ;;
  *) die "未知子命令：${cmd}（用 --help 看用法）" ;;
esac
