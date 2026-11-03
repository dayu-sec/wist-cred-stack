# Changelog

## [Unreleased]

### Added

- **示例验证方** `dev/peer-example/`：一个**独立 crate**，依赖走已发布的 `wist-cred-peer`
  （不引本地 path），就是「一个服务怎么接入 cred」的样板。
  - `./dev/svc.sh start peer`：建系统 → 跑一次真实接入命令拿证书 → 起 mTLS 服务（:19455）；
  - `./dev/svc.sh peer-check`：签发 → 推送 → 本地验证 → 撤销 → 再验证，一条命令跑完；
  - `status` / `logs` / `stop` 都认 `peer`；它不随默认 `start` 启动（要先建系统、走接入）。

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
