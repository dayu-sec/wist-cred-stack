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
#   configs/web/htpasswd                   入口 basic auth（由密钥文件的 cred_web_password 生成）
#
# 环境（gops 把合并后的系统变量以环境变量注入）：
#   CRED_IP / WEB_IP / CRED_MAX_TTL_SECONDS / CRED_BREAK_GLASS_TTL_SECONDS /
#   CRED_OVERLAP_SECONDS / CRED_ONBOARDING_TTL_SECONDS / CRED_PEER_CERT_TTL_SECONDS /
#   CRED_HEARTBEAT_SECONDS / WEB_HTPASSWD
#
# 本服务**不持凭据明文**：签发的 token 只在创建响应出现一次，库里只有 sha256 摘要。
# 本站唯一的口令是入口 basic auth，它**只**来自栈根密钥文件
# `.wist/sec-value.yml`（`cred_web_password`），脚本不回显、不进配置、不进 .env。
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

# ④ 入口认证（basic auth）
#
# 口令的**唯一来源**是栈根密钥文件（`sys-prj.yml: secrets.file`）：
#
#   .wist/sec-value.yml   →   cred_web_password: "..."
#
# 这里只把它算成 apr1 摘要写进 `configs/web/htpasswd`：口令不进配置、不进 .env、不回显。
# 换口令 = 改密钥 + 重跑 localize（不需要删 htpasswd）。
#
# **缺密钥就让 localize 失败**，不随机生成：脚本一生成，口令就落进终端 / CI 日志，
# 而且“现场有个没人知道来历的口令”比“起不来”更难查。补密钥的命令见 README「起栈」。

# 密钥读取统一走 gops：路径解析、文件模式、格式、值类型都由它校验，
# 不在这里重复实现一遍（与 center / gateway 的 `scripts/lib/sec.sh` 同一口径）。
#   · `gops sec` 以**当前目录**的系统清单为准 → 显式 cd 到栈根；
#   · 成功时屏蔽 stderr（每次调用会打一行版本横幅），键缺失返回空串；
#   · 文件本身不合格（不存在 / 权限过宽）→ 打错误信息并返回非零。
sec_get() {
  local key="$1" out
  if ! command -v gops >/dev/null 2>&1; then
    echo "错误：读取密钥 \`${key}\` 需要 gops（>= 2.8）；请确认 gops 在 PATH 上" >&2
    return 1
  fi
  if ! ( cd "${STACK_ROOT}" && gops sec list --json >/dev/null ); then
    echo "错误：密钥文件不可用（sys-prj.yml: secrets.file = .wist/sec-value.yml）" >&2
    return 1
  fi
  out="$( cd "${STACK_ROOT}" && gops sec get --show "${key}" 2>/dev/null )" || out=""
  printf '%s' "${out}"
}

# 同一个口令 + 同一个 salt 算出来的 apr1 是确定的：先比对，没变就不重写文件
# （重写会改 mtime，触发容器重载入口配置）。
apr1_matches() {
  local password="$1" line="$2" salt
  salt="$(printf '%s' "${line}" | awk -F'\\$' '{print $3}')"
  [[ -n "${salt}" ]] || return 1
  [[ "$(openssl passwd -apr1 -salt "${salt}" "${password}")" == "${line#admin:}" ]]
}

password="$(sec_get cred_web_password)" || exit 1
if [[ -z "${password}" ]]; then
  cat >&2 <<'MSG'
错误：入口口令没有来源。

  .wist/sec-value.yml 里缺 cred_web_password。补上（口令就是下面生成的那串）：

    mkdir -p .wist && chmod 700 .wist
    printf 'cred_web_password: "%s"\n' "$(openssl rand -hex 12)" > .wist/sec-value.yml
    chmod 600 .wist/sec-value.yml

  然后重跑 gops sys localize（登录：用户名 admin，口令同上）。
MSG
  exit 1
fi

current=""
if [[ -f "${WEB_HTPASSWD}" ]]; then
  current="$(sed -n 's/^admin://p' "${WEB_HTPASSWD}" | head -n 1)"
fi
if [[ -n "${current}" ]] && apr1_matches "${password}" "${current}"; then
  note "入口口令与密钥文件一致，跳过：${WEB_HTPASSWD}"
else
  if ! hash="$(openssl passwd -apr1 "${password}")"; then
    echo "生成 htpasswd 失败（需要 openssl passwd -apr1）" >&2
    exit 1
  fi
  # 先写临时文件再替换：nginx 可能正读着，不留半截文件。
  tmp="$(mktemp "${WEB_HTPASSWD}.XXXXXX")"
  printf 'admin:%s\n' "${hash}" >"${tmp}"
  chmod 640 "${tmp}"
  mv -f "${tmp}" "${WEB_HTPASSWD}"
  note "已按密钥文件写入入口口令（用户名 admin，不回显）：${WEB_HTPASSWD}"
fi
