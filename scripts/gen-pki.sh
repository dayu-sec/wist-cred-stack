#!/usr/bin/env bash
# 生成凭据服务（cred）↔ 验证方（X）双向认证所需的 PKI 与接入包。
#
# 用法：
#   scripts/gen-pki.sh [identity_dir] [name=host ...]
#     scripts/gen-pki.sh identity/cred wist-ingest=ingest.internal wist-center=center.internal
#
# `CRED_PKI_PEERS` 里每项还可以带第三个字段（推送 endpoint），本脚本**只看前两个**，
# 推送地址由 init-cred.sh 读同一份变量抽出来。
#
# 产物（**一把 CA 只干一件事**，与 center 的 CA-S / CA-I 同口径）：
#
#   ca-s.crt / ca-s.key          站点服务器 CA：**运行期**按 CSR 签每个 X 的服务器证书
#                                → 交给 cred 当信任锚（校 X 是谁）
#                                → 私钥挂在 cred 侧，它是签发方（与 center 持 CA-G 同构）
#   ca-i.crt / ca-i.key          内部服务 CA：签 cred 的**客户端**证书
#                                → 证书（不含私钥）复制给每个 X 当 client_ca
#   cred-client.crt / .key       cred 的客户端证书（CN=wist-cred，EKU=clientAuth）
#   onboarding/<name>/           给这个 X 的接入包（**只有公开材料**）：
#                                 client-ca.pem   客户端 CA（= ca-i.crt）
#                                 peer.json       {name, host, endpoint}，cred 启动时读它
#
# ⚠ 这里**不生成任何 X 的私钥**。X 在自己的机器上现生成密钥对，只交 CSR ——
#   与 `wist-center` ↔ `wist-gwlinkd` 的入场流程同一口径（私钥永不出本机）。
#
# 幂等是**逐件**的：CA 与 cred 客户端证书存在就不动；peer 的接入包只补齐公开材料，
# 已有的一律不重签（重签会让已经生效的双向认证全部失效）。
#
# 迁移：旧版曾在这里生成 X 的服务器**私钥**并塞进一次性链接。那是不对的
# （私钥应该只在 X 本机存在），发现遗留文件就删掉并提示。
set -euo pipefail

IDENTITY_DIR="${1:-identity/cred}"
if [[ $# -gt 0 ]]; then shift; fi

# bash 3.2（macOS 自带）在 `set -u` 下对空数组的 ${#arr[@]} 会报错，
# 所以用字符串收集参数——peer 规格里不含空白，按词切分是安全的。
PEER_SPECS="$*"
if [[ -z "${PEER_SPECS}" ]]; then
  PEER_SPECS="wist-ingest=ingest.internal"
fi

note() { echo "  $*"; }

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

# `openssl req -addext` 在 LibreSSL（macOS 自带）上不可用 → 用配置文件写扩展。
ca_conf() {
  local cn="$1" out="$2"
  cat >"${out}" <<EOF
[req]
distinguished_name = dn
x509_extensions    = v3
prompt             = no
[dn]
CN = ${cn}
[v3]
basicConstraints = critical, CA:TRUE
keyUsage         = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
EOF
}

leaf_conf() {
  local name="$1" san_dns="$2" eku="$3" out="$4"
  cat >"${out}" <<EOF
[req]
distinguished_name = dn
prompt             = no
[dn]
CN = ${name}
[v3]
basicConstraints = critical, CA:FALSE
keyUsage         = critical, digitalSignature, keyEncipherment
extendedKeyUsage = ${eku}
subjectAltName   = DNS:${san_dns}
authorityKeyIdentifier = keyid,issuer
EOF
}

# 签一张叶证书：$1 配置前缀 $2 CN $3 SAN $4 EKU $5 输出前缀 $6 CA crt $7 CA key
sign_leaf() {
  local prefix="$1" cn="$2" san="$3" eku="$4" out="$5" ca_crt="$6" ca_key="$7"
  leaf_conf "${cn}" "${san}" "${eku}" "${work}/${prefix}.conf"
  openssl req -newkey rsa:2048 -nodes \
    -keyout "${out}.key" -out "${work}/${prefix}.csr" \
    -config "${work}/${prefix}.conf" >/dev/null 2>&1
  openssl x509 -req -in "${work}/${prefix}.csr" -days 730 \
    -CA "${ca_crt}" -CAkey "${ca_key}" -CAcreateserial \
    -extfile "${work}/${prefix}.conf" -extensions v3 \
    -out "${out}.crt" >/dev/null 2>&1
  chmod 600 "${out}.key"
  chmod 644 "${out}.crt"
}

mkdir -p "${IDENTITY_DIR}" "${IDENTITY_DIR}/onboarding"

# ── 两把 CA（存在就不动）───────────────────────────────────────────────────
if [[ -f "${IDENTITY_DIR}/ca-s.crt" && -f "${IDENTITY_DIR}/ca-s.key" ]]; then
  note "CA-S 已存在，跳过"
else
  ca_conf "wist site server CA" "${work}/ca-s.conf"
  openssl req -x509 -newkey rsa:3072 -nodes -days 3650 \
    -keyout "${IDENTITY_DIR}/ca-s.key" -out "${IDENTITY_DIR}/ca-s.crt" \
    -config "${work}/ca-s.conf" >/dev/null 2>&1
  chmod 600 "${IDENTITY_DIR}/ca-s.key"
  note "已生成 CA-S（签验证方服务器证书）"
fi

if [[ -f "${IDENTITY_DIR}/ca-i.crt" && -f "${IDENTITY_DIR}/ca-i.key" ]]; then
  note "CA-I 已存在，跳过"
else
  ca_conf "wist internal service CA" "${work}/ca-i.conf"
  openssl req -x509 -newkey rsa:3072 -nodes -days 3650 \
    -keyout "${IDENTITY_DIR}/ca-i.key" -out "${IDENTITY_DIR}/ca-i.crt" \
    -config "${work}/ca-i.conf" >/dev/null 2>&1
  chmod 600 "${IDENTITY_DIR}/ca-i.key"
  note "已生成 CA-I（签 cred 客户端证书）"
fi
chmod 644 "${IDENTITY_DIR}/ca-s.crt" "${IDENTITY_DIR}/ca-i.crt"

# ── 授权记录的签名钥（Ed25519；存在就不动）───────────────────────────────
#
# 它和上面两把 CA **不是一回事**：CA 负责“谁是谁”（mTLS），这把钥负责
# “这条授权记录确实是 cred 发的”（篡改检测）。私钥只在 cred 侧。
# 公钥（裸 32 字节 hex）作为公开材料给验证方，由接入脚本下发。
if [[ -f "${IDENTITY_DIR}/signing.key" ]]; then
  note "授权签名钥已存在，跳过"
else
  if ! openssl genpkey -algorithm ed25519 -out "${IDENTITY_DIR}/signing.key" >/dev/null 2>&1; then
    echo "错误：当前 openssl 不支持 Ed25519（需要 OpenSSL 3.x）" >&2
    exit 1
  fi
  chmod 600 "${IDENTITY_DIR}/signing.key"
  note "已生成授权签名钥（Ed25519）"
fi
# 公开公钥：裸 32 字节的 hex（验证方与运维都读这个格式）。
if [[ -f "${IDENTITY_DIR}/signing.key" ]]; then
  openssl pkey -in "${IDENTITY_DIR}/signing.key" -pubout -outform DER 2>/dev/null \
    | tail -c 32 | od -An -tx1 | tr -d ' \n' >"${IDENTITY_DIR}/signing.pub"
  chmod 644 "${IDENTITY_DIR}/signing.pub"
fi

# ── cred 的客户端证书（CA-I 签；存在就不动）────────────────────────────────
if [[ -f "${IDENTITY_DIR}/cred-client.crt" && -f "${IDENTITY_DIR}/cred-client.key" ]]; then
  note "cred 客户端证书已存在，跳过"
else
  sign_leaf "cred-client" "wist-cred" "wist-cred" "clientAuth" \
    "${IDENTITY_DIR}/cred-client" "${IDENTITY_DIR}/ca-i.crt" "${IDENTITY_DIR}/ca-i.key"
  note "已签发 cred 客户端证书（CN=wist-cred）"
fi

# ── 每个验证方一个接入包（只给新名字补签）─────────────────────────────────
for spec in ${PEER_SPECS}; do
  case "${spec}" in
    *=*) name="${spec%%=*}"; rest="${spec#*=}" ;;
    *)   echo "peer 规格必须是 name=host，收到：${spec}" >&2; exit 2 ;;
  esac
  # 允许 `name=host=endpoint`：endpoint 不参与签证书，写进 peer.json 供推送/心跳用。
  host="${rest%%=*}"
  if [[ "${rest}" == *=* ]]; then endpoint="${rest#*=}" ; else endpoint="" ; fi
  if [[ -z "${name}" || -z "${host}" ]]; then
    echo "peer 规格 name/host 都不能为空：${spec}" >&2
    exit 2
  fi
  # 只允许安全字符：这个值会变成目录名与配置文件里的字段。
  if [[ ! "${name}" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
    echo "peer 名只能用 [a-z0-9-] 且首尾为字母数字：${name}" >&2
    exit 2
  fi

  # 没有收数地址就不能推送，也不能被探活 —— 注册表里会显示成 `no_endpoint`，
  # 接入脚本会拒跑（要手工分发就显式 `--manual`）。部署时就把它说出来，
  # 不留到接入那一刻才发现“登记成功、却什么都不动”。
  if [[ -z "${endpoint}" ]]; then
    echo "  ⚠ ${name}（${host}）没有收数地址：将显示为 no_endpoint（不探活、不推送）" >&2
    echo "    需要推送请写成 ${name}=${host}=https://${host}:<端口>/api/v1/internal/credentials" >&2
    echo "    确实只做人工分发：接入时显式加 --manual。" >&2
  fi

  dest="${IDENTITY_DIR}/onboarding/${name}"

  # 迁移：旧版遗留的 X 私钥副本（曾经被塞进一次性链接）。删掉它。
  if [[ -f "${dest}/server.key" || -f "${dest}/server.crt" ]]; then
    rm -f "${dest}/server.key" "${dest}/server.crt"
    note "已删除旧版遗留的 ${name} 服务器密钥/证书（那个私钥不该存在这里，X 端请重新接入）"
  fi

  if [[ -f "${dest}/client-ca.pem" && -f "${dest}/peer.json" ]]; then
    # 材料齐了；但 peer.json 是元数据（不是密钥材料），endpoint 改了要能生效——
    # 按内容比对，变了就重写。
    if ! grep -q "\"endpoint\": \"${endpoint}\"" "${dest}/peer.json" 2>/dev/null; then
      cat >"${dest}/peer.json" <<EOF
{
  "name": "${name}",
  "host": "${host}",
  "endpoint": "${endpoint}"
}
EOF
      chmod 644 "${dest}/peer.json"
      note "${name}（${host}）地址已更新：${endpoint:-（手工分发）}"
    else
      note "${name}（${host}）接入包已存在，跳过"
    fi
    # 注意：注册表（state/peers.json）里已有的条目不会被种子覆盖，
    # 所以改了这里还需要在页面上同步（或删掉 state/peers.json 让它重新导入）。
    continue
  fi

  mkdir -p "${dest}"
  cp "${IDENTITY_DIR}/ca-i.crt" "${dest}/client-ca.pem"
  chmod 644 "${dest}/client-ca.pem"
  cat >"${dest}/peer.json" <<EOF
{
  "name": "${name}",
  "host": "${host}",
  "endpoint": "${endpoint}"
}
EOF
  chmod 644 "${dest}/peer.json"
  note "已写入 ${name} 接入包（公开材料；服务器证书由本机 CSR 在运行期换）"
done

# ── 演示用验证方（可选）────────────────────────────────────────────────────
#
# `CRED_DEMO_PEER` 非空才做两件事：
#   1. 用 CA-S 给这个名字签一张**服务器证书**（SAN = 服务名），材料落 `identity/demo-peer/`；
#   2. 在 onboarding/<name>/peer.json 里写一条种子（含收数地址与可验角色），
#      cred 启动时导入 —— 所以它**不需要**走一键接入（那是给真机器用的）。
#
# 私钥是宿主生成的，与“X 本机生成”的正常流程不同。这是刻意的例外：
# demo peer 就是这个栈自己拉起的旁路服务（sidecar），不是外部机器。
DEMO_PEER="${CRED_DEMO_PEER:-}"
if [[ -n "${DEMO_PEER}" ]]; then
  demo_dir="$(dirname "${IDENTITY_DIR}")/demo-peer"
  if [[ -f "${demo_dir}/server.crt" && -f "${demo_dir}/server.key" ]]; then
    note "演示验证方 ${DEMO_PEER} 的证书已存在，跳过"
  else
    mkdir -p "${demo_dir}"
    sign_leaf "demo-peer" "${DEMO_PEER}" "${DEMO_PEER}" "serverAuth" \
      "${demo_dir}/server" "${IDENTITY_DIR}/ca-s.crt" "${IDENTITY_DIR}/ca-s.key"
    note "已签发演示验证方证书（CN/SAN=${DEMO_PEER}，CA-S 签）"
  fi

  # 信任锚：cred 出示的客户端证书由 CA-I 签（peer-example 默认读 `<dir>/client-ca.pem`）。
  # **复制进同一个目录**而不是在 compose 里挂第二个文件：`/certs` 已经是只读挂载，
  # 往只读目录里再 bind 一个文件时 Docker 建不了挂载点（`read-only file system`）。
  install -m 644 "${IDENTITY_DIR}/ca-i.crt" "${demo_dir}/client-ca.pem"
  # 授权记录签名公钥：demo peer 用它验签（`--issuer-public-key-file`）。
  install -m 644 "${IDENTITY_DIR}/signing.pub" "${demo_dir}/issuer-signing.pub"

  # 角色 → JSON 字符串数组（与接入脚本里那段同一写法）。
  demo_roles="${CRED_DEMO_PEER_ROLES:-read,investigation:run}"
  demo_roles_json="$(printf '%s' "${demo_roles}" | tr ',' '\n' \
    | awk '{ gsub(/^[ \t]+|[ \t]+$/, ""); if ($0 != "") printf "%s\"%s\"", (n++ ? ", " : ""), $0 }')"

  demo_seed="${IDENTITY_DIR}/onboarding/${DEMO_PEER}"
  mkdir -p "${demo_seed}"
  cat >"${demo_seed}/peer.json" <<EOF
{
  "name": "${DEMO_PEER}",
  "host": "${DEMO_PEER}",
  "endpoint": "https://${DEMO_PEER}:19443/api/v1/internal/credentials",
  "roles": [${demo_roles_json}]
}
EOF
  chmod 644 "${demo_seed}/peer.json"
  note "演示验证方种子：${demo_seed}/peer.json（roles: ${demo_roles}）"
fi

echo
note "CA-S（信任锚 + 签发用）：      ${IDENTITY_DIR}/ca-s.crt（私钥只给 cred）"
note "CA-I（交给 X 当 client_ca）：  ${IDENTITY_DIR}/ca-i.crt"
note "cred 客户端证书：              ${IDENTITY_DIR}/cred-client.{crt,key}"
note "验证方接入包（仅公开材料）：    ${IDENTITY_DIR}/onboarding/<name>/"
note "新增验证方：带上新的 name=host 重跑本脚本，已有材料不动。"
