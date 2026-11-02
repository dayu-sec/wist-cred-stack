# wist-cred-stack

凭据服务 `wist-cred` + 管理页面 `wist-cred-web` 的一站式部署栈（gops）。

> 设计口径：`wist-design/doc/design/foundation/auth-token-verification.md`
> （D15 签发独立在计算区、D17 页面与认证解耦、S1/S3 的 listener 与 peer 约束）。

## 拓扑

```text
        浏览器 / 内网反代
              │ HTTPS（basic auth）
              ▼
      web（nginx，容器内 443）        ← 宿主发布 ${WEB_BIND_IP}:${WEB_HOST_PORT}
              │ http://<cred>:8443     ← 只走专用 docker 网络
              ▼
      cred（wist-cred，容器内 8443）   ← **不对宿主发布任何端口**
              │
              └── /wist-cred/state/credentials.db（只存 sha256 摘要）
```

**为什么 cred 不发布端口**：它的入站是 plain HTTP + peer IP 白名单（S3），
TLS 在 web 终止。两者在专用网段（默认 `172.28.90.0/24`）里钉死 IP，
`trusted_peers` 才写得住（只允许 web 的地址）。

## 起栈

```sh
# 1) 改现场值（不要改 sys/setting/vars.yml）
#    ops-prj 的 values/wist-cred-stack/sys_value.yml：
#      WEB_DOMAIN: cred.<zone>
#      WEB_BIND_IP: <内网网卡或 127.0.0.1>

# 2) 变量解析 + 渲染（localize 会跑 scripts/init-cred.sh，并在缺失时打印 bootstrap 口令）
gops sys update
gops sys localize

# 3) 起
gops run start
```

第一次 localize 会生成：

| 产物 | 说明 |
|---|---|
| `identity/cred/server.{crt,key}` | 入口 nginx 的站点身份（自签；换正式证书直接覆盖文件） |
| `configs/cred/wist-cred.toml` | cred 运行配置（由 `sys/configs/cred/wist-cred.toml.tpl` 渲染） |
| `configs/web/nginx.conf` | 入口配置（由 `sys/configs/web/nginx.conf.tpl` 渲染） |
| `configs/web/htpasswd` | 阶段一的入口认证，`admin` + 随机口令（**只打印一次**） |

## 开发态（本地跑，不进 docker）

```sh
./dev/svc.sh start          # cargo build + 起 cred（127.0.0.1:18443）
./dev/svc.sh status         # 进程 / 端口 / 表里条目数
./dev/svc.sh token          # 创建一条凭据，打印明文（只此一次）
./dev/svc.sh verify <token> # 用 wist-auth 的**真实实现**验一条 token
./dev/svc.sh demo           # 签发 → 验证 → 撤销 → 再验证（一键闭环）
./dev/svc.sh logs -f
./dev/svc.sh stop
```

dev 态刻意不装 nginx、不做 TLS：`x-wist-operator` 由你显式带（`DEV_OPERATOR`，默认 `dev`）。
凭据表落 `dev/configs/state/`，与发布态互不影响。

依赖同级仓库（可用 env 覆盖）：

| env | 默认 |
|---|---|
| `WIST_CRED_SRC` | `../../wist/wist-cred` |
| `WIST_AUTH_SRC` | `../../wist/wist-auth` |
| `DEV_ADDR` | `127.0.0.1:18443` |

## 两条约束不是文案，是启动期会拦的

| 约束 | 会在哪里被拦 |
|---|---|
| `listen_addr` 不能是 `0.0.0.0` / `[::]`（S1） | `wist-cred` **加载配置时直接退出** |
| `trusted_peers` 为空（S3 前提） | 同上 |
| 对端不在 `trusted_peers` | 每个请求 `401 untrusted_ingress_peer` + 告警 |

所以 `configs/cred/wist-cred.toml` 里的 `listen_addr` 必须是容器在 `crednet` 里的私网 IP，
容器 IP 变了（比如改了 `CRED_NET_SUBNET` / `CRED_IP`）就要重新 localize。

## 阶段与边界

| 项 | 状态 |
|---|---|
| 入口认证 | 阶段一 **basic auth**（`$remote_user` → `x-wist-operator`）。将来接用户中心 / 钉钉 OIDC 只换 nginx 这一层，下游不动（D17） |
| 签发 → 验证方推送 | **P3，未实现**。当前是 P2：人工分发登记表（凭据表可直接作为 X 侧种子） |
| 存储 | 单文件 JSON（`configs/cred/state/credentials.db`），无数据库 |
| 密钥 | **本服务目前不持任何密钥**；P3 推送时才需要 CA-I 客户端证书 |

## 变量

全部在 `sys/setting/vars.yml`（产品默认值）；现场覆盖写 ops-prj 的 `values/wist-cred-stack/sys_value.yml`。
