# Changelog

## [0.2.0-alpha] - 2026-11-03

### 组件跟版

- `CRED_IMAGE_TAG` / `CRED_WEB_IMAGE_TAG` → `v0.2.0-alpha`（两个组件同版发布）。

### Changed

- **人机面的验证从入口 nginx 收回产品里**：页面有登录框（`wist-cred-web`），口令由
  `wist-cred` 自己验（`mode = "token"`）。入口 nginx 退回纯 TLS + 静态 + 反代。
  - `sys/configs/cred/wist-cred.toml.tpl`：`mode = "token"`，
    `admin_password = "${SEC_CRED_WEB_PASSWORD}"`（渲染物里永远只有占位符）；
    保留 `trusted_peers`（web 地址）当第二道锁。
  - compose：cred 挂 `.wist` 并设 `WIST_CRED_SEC_FILE`；web 删掉 htpasswd 挂载，
    nginx 不再做 `auth_basic`、不再注入 `x-wist-operator`。
  - `scripts/init-cred.sh`：不再生成 `configs/web/htpasswd`，改为只**检查**口令有没有来源
    （早一步报错，而不是等 cred 起不来）。
  - 变量 `WEB_HTPASSWD` 删除。
- `dev/svc.sh` 的开发态仍用 `mode = "ingress"`（vite 代理注入操作者头）——
  开发时不想每次输口令，且那条路本来只在 dev 存在。

### 升级注意

- **必须与组件一起发版**：`wist-cred` 需要带 `token` 模式的那一版（旧版会因不认识的
  `admin_password` 键**拒启**）；`wist-cred-web` 需要带登录框的那一版（旧版不会带
  `Authorization`，只会看到 401）。三个 tag 一起推。
- 口令先在 `.wist/sec-value.yml` 里放好（`cred_web_password`），否则 localize 当场失败。
- 升级后第一次打开页面会**先看到登录框**（口令 = `gops sec get --show cred_web_password`），
  不再有浏览器 basic auth 弹窗。

### Added

- **示例验证方** `dev/peer-example/`：一个**独立 crate**，依赖走已发布的 `wist-cred-peer`
  （不引本地 path），就是「一个服务怎么接入 cred」的样板。
  - `./dev/svc.sh start peer`：建系统 → 跑一次真实接入命令拿证书 → 起 mTLS 服务（:19455）；
  - `./dev/svc.sh peer-check`：签发 → 推送 → 本地验证 → 撤销 → 再验证，一条命令跑完；
  - `status` / `logs` / `stop` 都认 `peer`；它不随默认 `start` 启动（要先建系统、走接入）。
- **容器里的演示验证方（`COMPOSE_PROFILES=demo`）**：`CRED_DEMO_PEER` 非空时，localize 阶段用
  CA-S 给这个服务名签一张服务器证书并写种子（`identity/cred/onboarding/<name>/peer.json`），
  compose 的 `peer-demo` 服务直接拉起来 —— **不需要走一键接入**（那是给真机器用的）。
  默认关闭；开的时候两个变量一起写（`CRED_DEMO_PEER` + `COMPOSE_PROFILES`）。

### Changed

- **入口口令改为只存栈根密钥文件** `.wist/sec-value.yml` 的 `cred_web_password`
  （与 `wist-center-stack` / `wist-gateway-stack` 同一口径）：`scripts/init-cred.sh` 在 localize 时
  用 `gops sec get` 读它，只写 `configs/web/htpasswd` 的 apr1 摘要。
  - **行为变化**：不再“缺密钥就随机生成并打印一次”，改为 **fail-closed** —— 缺文件 / 缺键时
    localize 直接失败，并打印补密钥的命令。口令不再经过终端与 CI 日志。
  - 换口令 = 改密钥 + `gops sys localize`；同口令（同 salt）不重写 htpasswd（幂等，不无端重载入口）。
  - `.wist` 进 `sys-prj.yml` 的 `ignore` / `protect`：密钥不进交付包，升级也不碰。
- **入口 basic auth 提到 server 级**（`sys/configs/web/nginx.conf.tpl`）：以前只护 `/api/`，
  页面先加载出来、第一次 API 调用才弹认证框，用户取消后就是一片 401（看着像“没有登录入口”）。
  现在首屏 `/` 也验；`/onboarding/` 仍 `auth_basic off`（拿它的是机器，靠一次性券授权）。

## [0.1.1-alpha] - 2026-11-03

### 变更

- 默认镜像 tag 跟进到 `v0.1.1-alpha`（两个组件都发了这一版）。
- **镜像源是现场值，不是产品默认**：产品默认仍是 `ghcr.io/dayu-sec`；国内部署在
  `values/sys_value.yml` 里写 `CRED_REGISTRY: dy-sec.tencentcloudcr.com/cloud`，
  `gops sys localize` 即生效（与 gateway-stack 同一套口径）。镜像与 tag 由两个组件仓的
  release 流水线产出，本栈只负责编排。

## [0.1.0-alpha] - 2026-11-03

首个可部署栈：`wist-cred`（凭据服务）+ `wist-cred-web`（管理页面）一套编排，
带双向认证所需的 PKI 生成与验证方接入脚本。

### 新增

- **两个容器 + 一个宿主入口**：web 终止 TLS 并托管页面，`/api` 反代给 cred；
  cred 不发布任何宿主端口，只走专用网段（它的入站是明文 HTTP + 来源地址白名单）。
- **接入即用**：`scripts/gen-pki.sh` 生成两把 CA —— 一把签验证方的服务器证书，
  一把签 cred 自己的客户端证书（一把 CA 只干一件事）；验证方的私钥**从不生成在这里**。
- **验证方一键接入**：页面生成 `curl … | bash` 命令，对方机器上生成密钥、只交证书签名请求，
  证书运行期签出；`/onboarding/` 在入口上单独一条免认证 location，且不缓存。
- **可联通探测**：cred 用自己的客户端证书按周期探每个认证系统，页面显示在线/不通与延迟。
- `dev/svc.sh`：开发态一条命令起 cred + web（本地进程、不做 TLS），
  并提供 `token` / `verify` / `demo` / `onboard` 等自测入口；`verify`/`demo` 跑的是
  验证侧真实实现，不是模拟。
- 三个端到端自检脚本：接入（含券重放）、双向握手、心跳。

### 变更

- **认证系统改为运行期实体**：部署种子只负责首次导入，之后新增系统、改收数地址都在页面上做，
  不需要 `localize`、也不需要重启。
- 推送目标不再写进配置：一套共用身份 + 每个系统自己的地址，地址跟着注册表走。
- `dev/svc.sh demo` 的受众与角色改为从注册表读取，写死的名字在接入别的系统后会失效。

### 安全

- CA-I（签 cred 客户端证书）的**私钥不进容器**；容器只拿到公开证书当信任锚。
- 入口只由 nginx 写操作者身份头，客户端自带的同名头不会透传；cred 再用来源地址白名单二次确认。
- 站点私钥与 CRED 私钥只用只读挂载，逐个文件挂，不挂整个 identity 目录。
