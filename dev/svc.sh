#!/usr/bin/env bash
# 开发态统一入口：本地起 / 停 / 看 cred，外加一条龙验证。
#
# 只用本地进程，不进 docker、不需要 TLS、不需要 nginx：
#   · cred 直接监听 127.0.0.1（S1 允许私网/回环，绑定 0.0.0.0 会被拒绝启动）；
#   · `x-wist-operator` 由你显式带（dev 没有入口认证，别在 dev 之外这么用）；
#   · 凭据表落在 dev/configs/state/，与发布态互不影响。
#
# 用法：
#   ./dev/svc.sh start   [--no-build]   起 cred（默认先 cargo build）
#   ./dev/svc.sh stop                   停 cred
#   ./dev/svc.sh restart [--no-build]   停 + 起
#   ./dev/svc.sh status                 进程 / 端口 / 表里条目数
#   ./dev/svc.sh logs [-f]              看日志
#   ./dev/svc.sh token   [选项]         创建一条凭据并打印明文（只此一次）
#   ./dev/svc.sh verify  <token> [--audience wist-center]
#                                       用 wist-auth 的真实实现验一条 token
#   ./dev/svc.sh demo                   签发 → 验证 → 撤销 → 再验证（一键闭环）
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
#   WIST_CRED_SRC   组件仓路径（默认 ../../wist/wist-cred）
#   WIST_AUTH_SRC   验证库路径（默认 ../../wist/wist-auth）
#   DEV_ADDR        监听地址（默认 127.0.0.1:18443）
#   DEV_OPERATOR    操作者名（默认 dev）
#
# 注：dev 循环直接用 cargo build（跳过 gx 的版本同步 + 全量测试）；
#     提交 / 发版前仍以 `gx run lint` / `gx run build` 为准。
set -euo pipefail

STACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CRED_SRC="${WIST_CRED_SRC:-${STACK_ROOT}/../../wist/wist-cred}"
AUTH_SRC="${WIST_AUTH_SRC:-${STACK_ROOT}/../../wist/wist-auth}"

DEV_DIR="${STACK_ROOT}/dev"
CONF_DIR="${DEV_DIR}/configs"
STATE_DIR="${CONF_DIR}/state"
CONF="${CONF_DIR}/cred.toml"
RUN_DIR="${DEV_DIR}/.run"
PID_FILE="${RUN_DIR}/cred.pid"
LOG_FILE="${RUN_DIR}/cred.log"
BIN="${CRED_SRC}/target/debug/wist-cred"

ADDR="${DEV_ADDR:-127.0.0.1:18443}"
OPERATOR="${DEV_OPERATOR:-dev}"
BASE_URL="http://${ADDR}"

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

# ── 基础设施 ────────────────────────────────────────────────────────────────

write_config() {
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
EOF
  if [[ -f "${CONF}" ]] && cmp -s "${tmp}" "${CONF}"; then
    rm -f "${tmp}"
  else
    mv -f "${tmp}" "${CONF}"
    note "已写 dev 配置：${CONF}"
  fi
}

build() {
  [[ -d "${CRED_SRC}" ]] || die "找不到组件仓：${CRED_SRC}（用 WIST_CRED_SRC 指定）"
  note "构建 ${CRED_SRC} …"
  (cd "${CRED_SRC}" && cargo build --quiet)
}

cred_pid() {
  [[ -f "${PID_FILE}" ]] || return 1
  local pid
  pid="$(cat "${PID_FILE}" 2>/dev/null || true)"
  [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null && echo "${pid}"
}

healthy() {
  curl -fsS --max-time 1 "${BASE_URL}/healthz" >/dev/null 2>&1
}

wait_ready() {
  local i
  for i in $(seq 1 50); do
    healthy && return 0
    sleep 0.1
  done
  return 1
}

# ── 子命令 ──────────────────────────────────────────────────────────────────

cmd_start() {
  local do_build=1
  [[ "${1:-}" == "--no-build" ]] && do_build=0

  local pid
  if pid="$(cred_pid)"; then
    note "cred 已在运行（pid ${pid}，${BASE_URL}），复用。"
    return 0
  fi

  require_cmd curl
  write_config
  (( do_build )) && build
  [[ -x "${BIN}" ]] || die "没有二进制：${BIN}（先不带 --no-build 跑一次）"

  note "启动 cred：${BIN}"
  nohup "${BIN}" "${CONF}" >"${LOG_FILE}" 2>&1 &
  echo $! >"${PID_FILE}"

  if wait_ready; then
    note "就绪：${BASE_URL}（健康检查通过）"
    note "日志：${LOG_FILE}"
  else
    echo "启动失败，日志尾部：" >&2
    tail -n 20 "${LOG_FILE}" >&2 || true
    rm -f "${PID_FILE}"
    exit 1
  fi
}

cmd_stop() {
  local pid
  if ! pid="$(cred_pid)"; then
    note "cred 没在跑。"
    rm -f "${PID_FILE}"
    return 0
  fi
  note "停止 cred（pid ${pid}）"
  kill "${pid}" 2>/dev/null || true
  local i
  for i in $(seq 1 30); do
    kill -0 "${pid}" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "${pid}" 2>/dev/null; then
    kill -9 "${pid}" 2>/dev/null || true
  fi
  rm -f "${PID_FILE}"
}

cmd_status() {
  local pid state="stopped"
  pid="$(cred_pid || true)"
  [[ -n "${pid}" ]] && state="running (pid ${pid})"

  echo "cred   : ${state}"
  echo "addr   : ${BASE_URL}"
  echo "config : ${CONF}"
  echo "store  : ${STATE_DIR}/credentials.db"
  if healthy; then
    echo "health : ok"
    if command -v jq >/dev/null 2>&1; then
      echo "entries: $(curl -fsS "${BASE_URL}/api/v1/credentials" \
        -H "x-wist-operator: ${OPERATOR}" | jq '.credentials | length')"
    fi
  else
    echo "health : 不可达"
  fi
}

cmd_logs() {
  [[ -f "${LOG_FILE}" ]] || die "还没有日志：${LOG_FILE}"
  if [[ "${1:-}" == "-f" ]]; then
    tail -f "${LOG_FILE}"
  else
    tail -n 50 "${LOG_FILE}"
  fi
}

cmd_token() {
  require_cmd curl
  require_cmd jq
  healthy || die "cred 没在跑，先 ./dev/svc.sh start"

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
  require_cmd curl
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

cmd_demo() {
  require_cmd curl
  require_cmd jq
  healthy || die "cred 没在跑，先 ./dev/svc.sh start"

  local created token id audience
  created="$(curl -fsS -X POST "${BASE_URL}/api/v1/credentials" \
    -H "x-wist-operator: ${OPERATOR}" \
    -H 'content-type: application/json' \
    -d '{"subject":"ci-nightly","purpose":"dev demo","roles":["investigation:run"],"resources":{"agents":["agent-7f3"]},"audience":"wist-center"}')"
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

# ── 入口 ────────────────────────────────────────────────────────────────────

cmd="${1:-}"
shift || true

case "${cmd}" in
  start) cmd_start "$@" ;;
  stop) cmd_stop ;;
  restart)
    cmd_stop
    cmd_start "$@"
    ;;
  status) cmd_status ;;
  logs) cmd_logs "$@" ;;
  token) cmd_token "$@" ;;
  verify) cmd_verify "$@" ;;
  demo) cmd_demo ;;
  "" | -h | --help | help) usage ;;
  *) die "未知子命令：${cmd}（用 --help 看用法）" ;;
esac
