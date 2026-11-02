#!/usr/bin/env bash
# 开发态统一入口：本地起 / 停 / 看 cred 与 web，外加一条龙验证。
#
# 组件（不给 = 默认全部：cred web；也可写 all）：
#   cred   凭据服务后端（cargo run，默认 http://127.0.0.1:18443）
#   web    管理页面（vite dev，默认 http://127.0.0.1:5174，/api 反代到 cred 并注入操作者头）
#
# 用法：
#   ./dev/svc.sh start   [组件…] [--no-build]   默认全部
#   ./dev/svc.sh stop    [组件…]                默认全部（逆序停）
#   ./dev/svc.sh restart [组件…] [--no-build]   停所选（逆序）再起回（正序）
#   ./dev/svc.sh status
#   ./dev/svc.sh logs    [cred|web] [-f]
#   ./dev/svc.sh token   [选项]                 创建一条凭据并打印明文（只此一次）
#   ./dev/svc.sh verify  <token> [--audience wist-center]
#   ./dev/svc.sh demo                           签发 → 验证 → 撤销 → 再验证
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
# 关于身份：dev 没有入口认证，`x-wist-operator` 由 vite 代理注入（发布态由 nginx
# 做完 basic auth 后注入）。浏览器始终不碰这个头。
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
CONF="${CONF_DIR}/cred.toml"
RUN_DIR="${DEV_DIR}/.run"
CRED_PID_FILE="${RUN_DIR}/cred.pid"
CRED_LOG="${RUN_DIR}/cred.log"
WEB_PID_FILE="${RUN_DIR}/web.pid"
WEB_LOG="${RUN_DIR}/web.log"
CRED_BIN="${CRED_SRC}/target/debug/wist-cred"
WEB_BIN="${WEB_SRC}/node_modules/.bin/vite"

ADDR="${DEV_ADDR:-127.0.0.1:18443}"
WEB_PORT="${WEB_PORT:-5174}"
OPERATOR="${DEV_OPERATOR:-dev}"
BASE_URL="http://${ADDR}"
WEB_URL="http://127.0.0.1:${WEB_PORT}"

ALL_COMPONENTS=(cred web)

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
  write_cred_config

  if [[ "${do_build}" == "1" ]]; then
    [[ -d "${CRED_SRC}" ]] || die "找不到后端仓：${CRED_SRC}（用 WIST_CRED_SRC 指定）"
    note "构建 ${CRED_SRC} …"
    (cd "${CRED_SRC}" && cargo build --quiet)
  fi
  [[ -x "${CRED_BIN}" ]] || die "没有二进制：${CRED_BIN}（先不带 --no-build 跑一次）"

  note "启动 cred：${CRED_BIN}"
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

# ── 组件调度 ────────────────────────────────────────────────────────────────

normalize_components() {
  local given=("$@")
  if [[ ${#given[@]} -eq 0 ]]; then
    printf '%s\n' "${ALL_COMPONENTS[@]}"
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
  echo
  echo "  日志：${CRED_LOG}   ${WEB_LOG}"
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
}

cmd_logs() {
  local target="cred"
  local follow=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      cred | web) target="$1"; shift ;;
      -f) follow=1; shift ;;
      *) die "未知参数：$1" ;;
    esac
  done
  local file="${CRED_LOG}"
  [[ "${target}" == "web" ]] && file="${WEB_LOG}"
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

cmd_demo() {
  require_cmd curl
  require_cmd jq
  cred_healthy || die "cred 没在跑，先 ./dev/svc.sh start cred"

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
  stop) cmd_stop "$@" ;;
  restart)
    local do_build=0 comps=()
    for arg in ${@+"$@"}; do
      if [[ "${arg}" == "--no-build" ]]; then
        do_build=1
      else
        comps+=("${arg}")
      fi
    done
    cmd_stop ${comps[@]+"${comps[@]}"}
    local start_args=(${comps[@]+"${comps[@]}"})
    if [[ "${do_build}" == "1" ]]; then
      start_args+=(--no-build)
    fi
    cmd_start ${start_args[@]+"${start_args[@]}"}
    ;;
  status) cmd_status ;;
  logs) cmd_logs "$@" ;;
  token) cmd_token "$@" ;;
  verify) cmd_verify "$@" ;;
  demo) cmd_demo ;;
  "" | -h | --help | help) usage ;;
  *) die "未知子命令：${cmd}（用 --help 看用法）" ;;
esac
