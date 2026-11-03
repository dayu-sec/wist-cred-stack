# wist-cred 运行配置**模板**（handlebars，由 localize 渲染）。
# src: 本文件（sys/configs/cred/wist-cred.toml.tpl）
# dst: configs/cred/wist-cred.toml（sys/docker-compose.yml 只把这个文件只读挂到容器 /wist-cred）
# 渲染值：configs/cred/wist-cred.value.json（scripts/init-cred.sh 生成）
#
# 两条与容器强相关的项（设计文档 S1 / S3）：
#   - `listen_addr` 必须是**容器在专用网段里的私网 IP**，不能是 0.0.0.0 ——
#     加载期会拒绝绑定 unspecified 地址（同一份代码绑到公网就是后门）；
#   - `trusted_peers` 只放 web 的地址：多一道锁（谁都不该从别的地址直接调 cred）。
#
# 人是怎么被验证的（`mode`）：
#   - `token`（本栈用）：页面里输口令 → 请求带 `Authorization: Bearer <口令>`，
#     **cred 自己验**（配置里只有口令的 sha256）。口令真值在栈根 `.wist/sec-value.yml`
#     的 `cred_web_password`，由 `WIST_CRED_SEC_FILE` 指向的文件在**加载时**展开、算完即丢。
#   - `ingress`：人身份由内网反代注入 `x-wist-operator`（开发态 `dev/svc.sh` 走这条）。
#
# 凭据本身**不落密钥**：明文只在创建响应里出现一次，库里只有 sha256 摘要。
# 认证系统（验证方 X）**不在这份配置里**：它们落在 `state/peers.json`，运行期可增删。

[server]
listen_addr = "{{cred_ip}}:8443"
mode = "token"
# 只写占位符：明文绝不落到这份渲染物里（它会进包、进备份、谁都能 cat）。
admin_password = "${SEC_CRED_WEB_PASSWORD}"
trusted_peers = ["{{web_ip}}/32"]

[storage]
# 只存 sha256 摘要；目录由 compose 挂载，可写。
path = "/wist-cred/state/credentials.db"

[issue]
digest = "sha256"
max_ttl_seconds = {{max_ttl_seconds}}
break_glass_max_ttl_seconds = {{break_glass_max_ttl_seconds}}
overlap_seconds = {{overlap_seconds}}

# ── 推送到认证系统：**一套身份，所有认证系统共用** ────────────────────────
# 两个方向不是同一把 CA：client_* 由 CA-I 签（证明"我是 cred"），
# ca 是 CA-S 信任锚（校 X 的服务器证书）。
# 没有这一段 = 不推送（全靠手工分发），心跳也不会跑。
[push]
client_cert = "/wist-cred/identity/cred-client.crt"
client_key = "/wist-cred/identity/cred-client.key"
ca = "/wist-cred/identity/ca-s.crt"
timeout_seconds = 10

# ── 认证系统接入 ────────────────────────────────────────────────────────────
# `dir`：部署态种子目录，启动时导入一次（已有的注册表条目不覆盖）。
# `store_path`：注册表本体，**运行期可写**——页面新建认证系统就落这里。
# `ca_cert` / `ca_key`（CA-S）：运行期按 X 交上来的 **CSR** 签它的服务器证书。
#   必须与上面 `[push].ca` 是同一把，否则会签出自己认不了的证书（加载期拒启）。
# `client_ca`（CA-I 的公开证书）：交给 X 当信任锚，用来验 cred 的客户端证书。
[onboarding]
dir = "/wist-cred/identity/onboarding"
store_path = "/wist-cred/state/peers.json"
# 一次性接入券有效期；上限 3600（加载期强制）。
script_ttl_seconds = {{onboarding_ttl_seconds}}
ca_cert = "/wist-cred/identity/ca-s.crt"
ca_key = "/wist-cred/identity/ca-s.key"
client_ca = "/wist-cred/identity/ca-i.crt"
# 签给 X 的服务器证书有效期（90d）。
peer_cert_ttl_seconds = {{peer_cert_ttl_seconds}}
# 心跳间隔：周期性地用 mTLS 探每个认证系统的 /healthz。
# 「能握手」比「能 ping 通」有意义得多——证书过期、链不对、时间偏都会在这里暴露。
# 0 = 关闭（页面会一直显示"未知"）。
heartbeat_seconds = {{heartbeat_seconds}}
