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

# ── 改名守卫：CRED_REGISTRY → WIST_SPC（与 wist-gateway-stack 对齐）──
# gops 对 values 里的**未知键是静默接受的**：旧键留着不会报错，镜像源会默默退回默认值
# （现场表现：以为在拉 TCR，实际拉的是 ghcr）。改名那一刻就该让人看见。
if [[ -n "${CRED_REGISTRY:-}" ]]; then
  echo "错误：变量 CRED_REGISTRY 已改名为 WIST_SPC（与 wist-gateway-stack 同名同义）。" >&2
  echo "     处置：把 values/<系统名>/sys_value.yml 里的 CRED_REGISTRY 改成 WIST_SPC" >&2
  echo "           （值不变，例如 WIST_SPC: ${CRED_REGISTRY}），再重跑 gops sys localize。" >&2
  exit 2
fi

CRED_IP="${CRED_IP:-172.28.90.10}"
WEB_IP="${WEB_IP:-172.28.90.11}"

# 对外基址：接入脚本里的“交 CSR”地址由 cred 拼**绝对地址**，而入口反代的 `$host` 不带端口。
# 所以这里把端口明确告诉它（443 不写，其余照写）。
PUBLIC_PORT="${WEB_HOST_PORT:-443}"
if [[ "${PUBLIC_PORT}" == "443" ]]; then
  PUBLIC_BASE="https://${DOMAIN}"
else
  PUBLIC_BASE="https://${DOMAIN}:${PUBLIC_PORT}"
fi
MAX_TTL="${CRED_MAX_TTL_SECONDS:-2592000}"
BREAK_GLASS_TTL="${CRED_BREAK_GLASS_TTL_SECONDS:-7776000}"
OVERLAP="${CRED_OVERLAP_SECONDS:-300}"
ONBOARDING_TTL="${CRED_ONBOARDING_TTL_SECONDS:-900}"
PEER_CERT_TTL="${CRED_PEER_CERT_TTL_SECONDS:-7776000}"
PUSH_TIMEOUT="${CRED_PUSH_TIMEOUT_SECONDS:-10}"
HEARTBEAT="${CRED_HEARTBEAT_SECONDS:-30}"
# peer 清单不进渲染值：它是 `state/peers.json` 的种子，由 `scripts/gen-pki.sh` 写成
# `identity/cred/onboarding/<name>/peer.json`，cred 启动时导入一次。
# 之后新增/修改都走页面（`POST /api/v1/peers`），不再改 vars。
#
# 但**材料目录**进渲染值：它取决于对方栈的目录布局，猜不出来（`identity/center/cred`
# 这种名字和 peer 名对不上的很常见），所以由本栈用 `CRED_PEER_DIRS` 显式声明。
# 格式守卫在这里做：写成 `wist-center`（忘了 `=目录`）时 localize 就失败，
# 而不是等到 cred 启动才报。
if [[ -n "${CRED_PEER_DIRS:-}" ]]; then
  IFS=',' read -r -a peer_dir_items <<< "${CRED_PEER_DIRS}"
  for item in "${peer_dir_items[@]}"; do
    item="${item%"${item##*[![:space:]]}"}"
    item="${item#"${item%%[![:space:]]*}"}"
    [[ -z "${item}" ]] && continue
    if [[ "${item}" != *=* || "${item%%=*}" == "" || "${item#*=}" == "" ]]; then
      echo "错误：CRED_PEER_DIRS 的项必须写成 name=目录（现在是 '${item}'）" >&2
      echo "     例：CRED_PEER_DIRS='wist-center=./identity/center/cred'" >&2
      exit 2
    fi
  done
fi

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

# ①b 授权记录的签名钥（Ed25519；缺失才生成）
#
# 与两把 CA 不是一回事：CA 管“谁是谁”（mTLS），这把钥管“这条授权记录确实是 cred 发的”。
# 公钥由接入脚本下发给验证方；私钥永远只在 cred 侧。
# 新生成的现场要重新生成一次接入命令，让验证方把 `issuer-signing.pub` 补下来。
if [[ ! -f "${IDENTITY_DIR}/signing.key" ]]; then
  if ! openssl genpkey -algorithm ed25519 -out "${IDENTITY_DIR}/signing.key" >/dev/null 2>&1; then
    echo "错误：当前 openssl 不支持 Ed25519（需要 OpenSSL 3.x）" >&2
    exit 1
  fi
  chmod 600 "${IDENTITY_DIR}/signing.key"
  note "已生成授权签名钥：${IDENTITY_DIR}/signing.key（验证方需重新接入以获取公钥）"
fi
# 公开公钥（裸 32 字节 hex）：demo peer / 运维都用它；与 pri.key 成对存在。
if [[ -f "${IDENTITY_DIR}/signing.key" && ! -f "${IDENTITY_DIR}/signing.pub" ]]; then
  openssl pkey -in "${IDENTITY_DIR}/signing.key" -pubout -outform DER 2>/dev/null \
    | tail -c 32 | od -An -tx1 | tr -d ' \n' >"${IDENTITY_DIR}/signing.pub"
  chmod 644 "${IDENTITY_DIR}/signing.pub"
  note "已派生签名公钥：${IDENTITY_DIR}/signing.pub"
fi

# ② cred 配置的渲染值
write_json "${CONFIG_DIR}/wist-cred.value.json" cat <<EOF
{
  "cred_ip": "${CRED_IP}",
  "web_ip": "${WEB_IP}",
  "public_base_url": "${PUBLIC_BASE}",
  "max_ttl_seconds": ${MAX_TTL},
  "break_glass_max_ttl_seconds": ${BREAK_GLASS_TTL},
  "overlap_seconds": ${OVERLAP},
  "onboarding_ttl_seconds": ${ONBOARDING_TTL},
  "peer_cert_ttl_seconds": ${PEER_CERT_TTL},
  "heartbeat_seconds": ${HEARTBEAT},
  "push_timeout_seconds": ${PUSH_TIMEOUT},
  "peer_dirs": "${CRED_PEER_DIRS:-}"
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
# 而且“现场有个没人知道来历的口令”比“起不来”更难查。

# 新站点（或刚 `gops prj import` 进来的站点）第一道坑就是“文件根本不存在”。
# 这时**先自己判**，把能照抄的命令怼到脸上：调 `gops sec list` 只会回一句
# “声明了就必须存在”，不说该敲什么，也不提属组/模式。
SEC_FILE="${STACK_ROOT}/.wist/sec-value.yml"
if [[ ! -f "${SEC_FILE}" ]]; then
  cat >&2 <<'MSG'
错误：密钥文件不存在（<栈根>/.wist/sec-value.yml）

  页面口令只存在这个文件里（不入库、不进交付包）。首次部署先建它：

    # ① 一次性前置（Linux）：容器以 gid 999 跑，密钥必须“属组可读”
    #    部署账号加入 gid 999（重新登录后生效）；.wist 用 setgid，新文件自动继承该组
    sudo usermod -aG 999 "$USER"
    mkdir -p .wist && chmod 2770 .wist

    # ② 生成口令（24 hex；这就是打开页面时要输的那串）
    printf 'cred_web_password: "%s"\n' "$(openssl rand -hex 12)" > .wist/sec-value.yml

    # ③ 权限收敛到 sys-prj.yml 的 secrets.mode（0640）；gops 只改 mode、不改属组
    chmod 640 .wist/sec-value.yml
    gops sec fix

  然后重跑 gops sys localize。
  （macOS / Docker Desktop 不看属组，① 可跳过。）
MSG
  exit 1
fi

# 密钥读取统一走 gops：路径解析、文件模式、格式、值类型都由它校验，
# 不在这里重复实现一遍（与 center / gateway 的 `scripts/lib/sec.sh` 同一口径）。
#   · `gops sec` 以**当前目录**的系统清单为准 → 显式 cd 到栈根；
#   · 成功时屏蔽 stderr（每次调用会打一行版本横幅），键缺失返回空串；
#   · 文件本身不合格（模式不对 / 格式坏 / 属组不对）→ 把 gops 的原因原样透出。
sec_get() {
  local key="$1" out
  if ! command -v gops >/dev/null 2>&1; then
    echo "错误：读取密钥 \`${key}\` 需要 gops（>= 2.8）；请确认 gops 在 PATH 上" >&2
    return 1
  fi
  if ! ( cd "${STACK_ROOT}" && gops sec list --json >/dev/null ); then
    # 文件在、但 gops 不认（模式与 secrets.mode 不符等）：把它的原文漏出来，
    # 再补一句怎么修 —— 否则现场只看得到 “密钥文件不可用”。
    echo "错误：密钥文件不合格（sys-prj.yml: secrets.file = .wist/sec-value.yml）；gops 说：" >&2
    ( cd "${STACK_ROOT}" && gops sec list >/dev/null ) || true
    echo "  修：chmod 640 .wist/sec-value.yml && gops sec fix（属组必须是容器 gid 999）" >&2
    return 1
  fi
  out="$( cd "${STACK_ROOT}" && gops sec get --show "${key}" 2>/dev/null )" || out=""
  printf '%s' "${out}"
}

password="$(sec_get cred_web_password)" || exit 1
if [[ -z "${password}" ]]; then
  cat >&2 <<'MSG'
错误：页面口令没有来源。

  .wist/sec-value.yml 在，但里面缺 cred_web_password。补一行（口令就是下面生成的那串）：

    printf 'cred_web_password: "%s"\n' "$(openssl rand -hex 12)" >> .wist/sec-value.yml
    gops sec fix

  然后重跑 gops sys localize。
MSG
  exit 1
fi
note "页面口令已就位（来自密钥文件，不回显）"
