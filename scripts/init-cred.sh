#!/usr/bin/env bash
# 备料凭据服务的**渲染值**与入口身份，localize 里 gx.tpl 的输入。
#
# 用法：
#   scripts/init-cred.sh <配置目录> <对外域名>
#     scripts/init-cred.sh configs/cred cred.example.com
#
# 产出（全部幂等；内容不变就不碰 mtime）：
#   identity/cred/server.{crt,key}         入口 nginx 的站点身份（自签；缺失即生成）
#   configs/cred/wist-cred.value.json      cred 配置模板的渲染值
#   configs/web/nginx.value.json           入口 nginx 的渲染值
#   configs/web/htpasswd                   阶段一的入口认证（缺失即补一个 bootstrap 用户）
#
# 环境（gops 把合并后的系统变量以环境变量注入）：
#   CRED_IP / WEB_IP / CRED_MAX_TTL_SECONDS / CRED_BREAK_GLASS_TTL_SECONDS /
#   CRED_OVERLAP_SECONDS / CRED_ONBOARDING_TTL_SECONDS / CRED_PEER_CERT_TTL_SECONDS /
#   CRED_HEARTBEAT_SECONDS / WEB_HTPASSWD
#   CRED_BOOTSTRAP_PASSWORD  可选：指定 bootstrap 账号口令（缺省随机生成并打印一次）
#
# 本服务**不持密钥**：凭据明文只在创建响应出现一次，落盘只有 sha256 摘要。
set -euo pipefail

CONFIG_DIR="${1:-configs/cred}"
DOMAIN="${2:-${WEB_DOMAIN:-}}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ -z "${DOMAIN}" ]]; then
  echo "用法: $0 <配置目录> <对外域名>" >&2
  exit 2
fi

CRED_IP="${CRED_IP:-172.28.90.10}"
WEB_IP="${WEB_IP:-172.28.90.11}"
MAX_TTL="${CRED_MAX_TTL_SECONDS:-2592000}"
BREAK_GLASS_TTL="${CRED_BREAK_GLASS_TTL_SECONDS:-7776000}"
OVERLAP="${CRED_OVERLAP_SECONDS:-300}"
ONBOARDING_TTL="${CRED_ONBOARDING_TTL_SECONDS:-900}"
PEER_CERT_TTL="${CRED_PEER_CERT_TTL_SECONDS:-7776000}"
HEARTBEAT="${CRED_HEARTBEAT_SECONDS:-30}"
# peer 清单不进渲染值：它是 `state/peers.json` 的种子，由 `scripts/gen-pki.sh` 写成
# `identity/cred/onboarding/<name>/peer.json`，cred 启动时导入一次。
# 之后新增/修改都走页面（`POST /api/v1/onboarding/peers`），不再改 vars。
WEB_HTPASSWD="${WEB_HTPASSWD:-configs/web/htpasswd}"

# web 的配置目录固定落栈根，避免脚本从别的工作目录被调用时写错地方。
WEB_CONFIG_DIR="${STACK_ROOT}/configs/web"
IDENTITY_DIR="${STACK_ROOT}/identity/cred"

# 相对路径统一锚到栈根（gops 通常就在栈根执行，但不依赖这一点）。
case "${CONFIG_DIR}" in
  /*) : ;;
  *) CONFIG_DIR="${STACK_ROOT}/${CONFIG_DIR}" ;;
esac
case "${WEB_HTPASSWD}" in
  /*) : ;;
  *) WEB_HTPASSWD="${STACK_ROOT}/${WEB_HTPASSWD}" ;;
esac

note() { echo "  $*"; }

# 渲染值只在内容变化时落盘，避免每次 localize 都触发容器重启。
write_json() {
  local dst="$1"
  shift
  local tmp
  tmp="$(mktemp "${dst}.XXXXXX")"
  "$@" >"${tmp}"
  chmod 644 "${tmp}"
  if [[ -f "${dst}" ]] && cmp -s "${tmp}" "${dst}"; then
    rm -f "${tmp}"
    note "渲染值一致，跳过：${dst}"
  else
    mv -f "${tmp}" "${dst}"
    note "已写渲染值：${dst}"
  fi
}

mkdir -p "${CONFIG_DIR}" "${CONFIG_DIR}/state" "${WEB_CONFIG_DIR}" "${IDENTITY_DIR}"

# ① 入口站点身份（缺失才生成）
"${SCRIPT_DIR}/ensure-cred-server-cert.sh" "${IDENTITY_DIR}" "${DOMAIN}"

# ② cred 配置的渲染值
write_json "${CONFIG_DIR}/wist-cred.value.json" cat <<EOF
{
  "cred_ip": "${CRED_IP}",
  "web_ip": "${WEB_IP}",
  "max_ttl_seconds": ${MAX_TTL},
  "break_glass_max_ttl_seconds": ${BREAK_GLASS_TTL},
  "overlap_seconds": ${OVERLAP},
  "onboarding_ttl_seconds": ${ONBOARDING_TTL},
  "peer_cert_ttl_seconds": ${PEER_CERT_TTL},
  "heartbeat_seconds": ${HEARTBEAT}
}
EOF

# ③ 入口 nginx 的渲染值
write_json "${WEB_CONFIG_DIR}/nginx.value.json" cat <<EOF
{
  "web_domain": "${DOMAIN}",
  "cred_ip": "${CRED_IP}"
}
EOF

# ④ 阶段一的入口认证
if [[ -f "${WEB_HTPASSWD}" ]]; then
  note "htpasswd 已存在，跳过：${WEB_HTPASSWD}"
else
  password="${CRED_BOOTSTRAP_PASSWORD:-$(openssl rand -hex 12)}"
  if ! hash="$(openssl passwd -apr1 "${password}")"; then
    echo "生成 htpasswd 失败（需要 openssl passwd -apr1）" >&2
    exit 1
  fi
  printf 'admin:%s\n' "${hash}" >"${WEB_HTPASSWD}"
  chmod 640 "${WEB_HTPASSWD}"
  note "已创建 bootstrap 账号（口令只显示这一次）："
  echo
  echo "    用户名: admin"
  echo "    口令:   ${password}"
  echo
  note "换口令：删掉 ${WEB_HTPASSWD} 后重新 localize。"
fi
