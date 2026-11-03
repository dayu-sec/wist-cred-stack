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
#
# 环境（gops 把合并后的系统变量以环境变量注入）：
#   CRED_IP / WEB_IP / CRED_MAX_TTL_SECONDS / CRED_BREAK_GLASS_TTL_SECONDS /
#   CRED_OVERLAP_SECONDS / CRED_ONBOARDING_TTL_SECONDS / CRED_PEER_CERT_TTL_SECONDS /
#   CRED_HEARTBEAT_SECONDS
#
# 本服务**不持凭据明文**：签发的 token 只在创建响应出现一次，库里只有 sha256 摘要。
# 页面口令也不在这里落盘：它只在栈根密钥文件 `.wist/sec-value.yml`（`cred_web_password`），
# 由 cred 启动时展开成 sha256；本脚本只检查它在不在。
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

# web 的配置目录固定落栈根，避免脚本从别的工作目录被调用时写错地方。
WEB_CONFIG_DIR="${STACK_ROOT}/configs/web"
IDENTITY_DIR="${STACK_ROOT}/identity/cred"

# 相对路径统一锚到栈根（gops 通常就在栈根执行，但不依赖这一点）。
case "${CONFIG_DIR}" in
  /*) : ;;
  *) CONFIG_DIR="${STACK_ROOT}/${CONFIG_DIR}" ;;
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

# ④ 页面口令的存在性检查（**这里不写任何文件**）
#
# 人是怎么被验证的：页面里输口令 → 请求带 `Authorization: Bearer <口令>` → **cred 自己验**
# （`mode = token`，配置里只有 sha256）。口令来源只有一个：
#
#   .wist/sec-value.yml   →   cred_web_password
#
# 为什么这里还要检查一遍：cred 加载时也会因为占位符解不出来而拒启（这是真正的 fail-closed），
# 但那是 `docker compose up` 之后才看到的。放在 localize 里，早一步、少一轮重启。
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

password="$(sec_get cred_web_password)" || exit 1
if [[ -z "${password}" ]]; then
  cat >&2 <<'MSG'
错误：页面口令没有来源。

  .wist/sec-value.yml 里缺 cred_web_password。补上（口令就是下面生成的那串）：

    mkdir -p .wist && chmod 700 .wist
    printf 'cred_web_password: "%s"\n' "$(openssl rand -hex 12)" > .wist/sec-value.yml
    chmod 600 .wist/sec-value.yml

  然后重跑 gops sys localize。这个口令就是打开页面时要输的那个。
MSG
  exit 1
fi
note "页面口令已就位（来自密钥文件，不回显）"
