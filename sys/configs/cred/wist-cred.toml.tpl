# wist-cred 运行配置**模板**（handlebars，由 localize 渲染）。
# src: 本文件（sys/configs/cred/wist-cred.toml.tpl）
# dst: configs/cred/wist-cred.toml（sys/docker-compose.yml 只把这个文件只读挂到容器 /wist-cred）
# 渲染值：configs/cred/wist-cred.value.json（scripts/init-cred.sh 生成）
#
# 两条与容器强相关的项（设计文档 S1 / S3）：
#   - `listen_addr` 必须是**容器在专用网段里的私网 IP**，不能是 0.0.0.0 ——
#     加载期会拒绝绑定 unspecified 地址（同一份代码绑到公网就是后门）；
#   - `trusted_peers` 只放 web 的地址：cred 的入站靠 peer IP 判定，不做 TLS。
#
# 本服务**不持密钥**：凭据明文只在创建响应里出现一次，库里只有 sha256 摘要。

[server]
listen_addr = "{{cred_ip}}:8443"
mode = "ingress"
ingress_header = "x-wist-operator"
trusted_peers = ["{{web_ip}}/32"]

[storage]
# 只存 sha256 摘要；目录由 compose 挂载，可写。
path = "/wist-cred/state/credentials.db"

[issue]
digest = "sha256"
max_ttl_seconds = {{max_ttl_seconds}}
break_glass_max_ttl_seconds = {{break_glass_max_ttl_seconds}}
overlap_seconds = {{overlap_seconds}}

# 推送目标（P3 才真正使用；P2 人工分发时这段留着也不影响启动 —— 路径不做启动期校验）。
# 两个方向不是同一个 CA：client_* 由 CA-I 签（证明"我是 cred"），
# ca 是 CA-S 信任锚（校 X 的服务器证书）。
[[issue.targets]]
name = "wist-center"
endpoint = "{{center_internal_url}}"
audience = "wist-center"
client_cert = "/wist-cred/identity/cred-client.crt"
client_key = "/wist-cred/identity/cred-client.key"
ca = "/wist-cred/identity/center-ca.pem"
