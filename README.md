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

# 2) 页面口令（**运维提供**，只在密钥文件里）
mkdir -p .wist && chmod 700 .wist
printf 'cred_web_password: "%s"\n' "$(openssl rand -hex 12)" > .wist/sec-value.yml
chmod 600 .wist/sec-value.yml
# → 打开页面要输的就是上面那串（用户名一概不需要：直接一个口令）

# 3) 变量解析 + 渲染（localize 会检查口令有没有来源）
gops sys update
gops sys localize

# 4) 起
gops run start
```

第一次 localize 会生成：

| 产物 | 说明 |
|---|---|
| `identity/cred/server.{crt,key}` | 入口 nginx 的站点身份（自签；换正式证书直接覆盖文件） |
| `configs/cred/wist-cred.toml` | cred 运行配置（由 `sys/configs/cred/wist-cred.toml.tpl` 渲染；口令位只写占位符） |
| `configs/web/nginx.conf` | 入口配置（由 `sys/configs/web/nginx.conf.tpl` 渲染；**不做认证**） |

### 人怎么进页面：登录框 + 口令由 cred 自己验

与服务端签发的 token 无关 —— 它管的是**谁能打开这个页面**，不是“程序拿什么调 API”。

```text
.wist/sec-value.yml          # 0600、不入库、不进交付包（sys-prj.yml 的 ignore/protect）
  cred_web_password: "..."   # → SEC_CRED_WEB_PASSWORD
         │                              │
         │                              └─ cred 启动时展开 → sha256（明文当场丢掉）
         └─ gops sys localize 只检查它在不在（不写任何文件）

浏览器：打开页面 → 登录框输口令 → 存本标签页 → 请求带 Authorization: Bearer <口令>
```

- **验证在产品里**：`wist-cred` 的 `mode = "token"` 自己比对；入口 nginx 只做 TLS / 静态 / 反代，
  不写身份、不注入头 —— 权限处理不在反代那一层；
- **口令怎么查 / 怎么换**：`gops sec get --show cred_web_password`；换口令 = 改密钥 +
  `gops sys localize` + 重启 cred（配置里只有摘要，重算很快）；
- **缺密钥 = 起不来**：localize 失败并打印补密钥的命令；就算漏过去，cred 加载时会因占位符
  解不出来拒启 —— 不会静默成“空口令也能进”；
- **机器 / 排查用 curl**：`curl -H "Authorization: Bearer $(gops sec get --show cred_web_password)" ...`；
- **`/onboarding/`（取接入脚本、登记）本来就不要口令**：拿它的是机器，
  授权靠 URL 里那张一次性券 + peer IP 白名单。

> 开发态（`./dev/svc.sh`）用的仍是 `mode = "ingress"`（vite 代理注入操作者头）——
> 开发时不想每次输口令；发布态一律 `token`。

### 演示用的验证方（可选）

想在不接任何真实系统的情况下验证「推送 / 心跳 / 撤销」整条链路，开一个 demo peer：

```yaml
# values/<系统>/sys_value.yml（两个一起开，缺一个都不会起作用）
CRED_DEMO_PEER: peer-demo
CRED_DEMO_PEER_ROLES: read,investigation:run
COMPOSE_PROFILES: demo
```

```sh
gops sys localize      # 用 CA-S 签一张 SAN=peer-demo 的服务器证书 + 写种子
gops run start         # compose 把 peer-demo 一并拉起
docker compose --project-directory . -f sys/docker-compose.yml --profile demo build  # 首次需要构建镜像
```

它**不走一键接入**：证书在 localize 阶段就签好了（宿主生成，因为它是本栈自己的旁路服务），
种子 `identity/cred/onboarding/peer-demo/peer.json` 在 cred 启动时导入 —— 所以 cred 一启动
就知道往 `https://peer-demo:19443/...` 推。摘要表放在容器内，重启会丢，正好用来试 API 的「重推」。

关掉时记得把 `identity/cred/onboarding/peer-demo/` 一起删了，否则 cred 仍会把它当成一个系统。

## 开发态（本地跑，不进 docker）

```sh
./dev/svc.sh start          # 起 cred（:18443）+ web（:5174）
./dev/svc.sh status         # 三个组件 + 表里条目数 + 各系统
./dev/svc.sh token          # 创建一条凭据，打印明文（只此一次）
./dev/svc.sh verify <token> # 用 wist-auth 的**真实实现**验一条 token
./dev/svc.sh demo           # 签发 → 验证 → 撤销 → 再验证（一键闭环）
./dev/svc.sh logs web -f
./dev/svc.sh stop

./dev/svc.sh start web      # 只起页面（cred 得已经在跑）
./dev/svc.sh restart cred   # 改了 Rust 代码后重启后端
```

### 示例验证方（`dev/peer-example`）

一个**独立 crate**，依赖走 crates.io 上已发布的 `wist-cred-peer`（不引本地 path）——
它就是「一个服务怎么接入 cred」的样板：收 `register`/`revoke`、维护自己的摘要表、
双向认证、心跳。

```sh
./dev/svc.sh start peer     # 建系统 peer-demo → 走一次接入命令拿证书 → 起 mTLS 服务（:19455）
./dev/svc.sh peer-check     # 签发 → 推给 peer → 本地验证 → 撤销 → 再验证
./dev/svc.sh status         # peer 的可联通状态
./dev/svc.sh logs peer -f
./dev/svc.sh stop peer
```

它不默认随 `start` 启动：需要先建系统、跑一次接入命令，不适合当默认组件。
材料落 `dev/.run/peer/`（含本机私钥，与 `/identity` 一样不入库）。

**页面在 <http://127.0.0.1:5174>**；`http://127.0.0.1:18443/` 只会返回一份自述 JSON。

dev 态不做入口认证：`x-wist-operator` 由 vite 代理注入（`DEV_OPERATOR`，默认 `dev`）。
凭据表落 `dev/configs/state/`，与发布态互不影响。

依赖同级仓库（可用 env 覆盖）：

| env | 默认 |
|---|---|
| `WIST_CRED_SRC` | `../../wist/wist-cred` |
| `WIST_CRED_WEB_SRC` | `../../wist/wist-cred-web` |
| `WIST_AUTH_SRC` | `../../wist/wist-auth` |
| `DEV_ADDR` | `127.0.0.1:18443` |
| `WEB_PORT` | `5174` |

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
