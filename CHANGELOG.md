# Changelog

## [0.4.16-alpha] - 2026-11-04

### 新增：`CRED_PEER_DIRS` —— 由本栈声明各认证系统的材料目录

接入命令在**对方的栈**里跑，落点取决于那个栈的目录布局（`identity/center/cred` 这种
名字和 peer 名对不上的很常见），猜不出来 —— 猜错就落在消费方不看的地方，而券已经烧了。

```yaml
CRED_PEER_DIRS: wist-center=./identity/center/cred,wist-ingest=./identity/ingest/cred
```

- 渲染进 `cred.toml` 的 `[onboarding] peer_dirs`（cred 0.4.16 开始支持）；
- cred 启动时**只补空**地填进注册表 —— 页面上存过的值优先，重启不会改回去；
- 格式错（忘写 `=目录` / 名字空 / 重复 / 含换行）在 **`gops sys localize` 阶段**就失败；
- 不声明 = 保持旧行为（脚本自己取默认）。

新增 `dev/tests/peer-dirs.test.sh`（9 项）：合法值进渲染值、四种坏格式被拒、
空值渲染为空串、value.json 仍是合法 JSON、模板确实用上了占位符。

> 升级注意：`CRED_IMAGE_TAG` 必须与它一起升（`peer_dirs` 对旧版 cred 是未知字段，会拒启）。

### 变更：跟版 cred 0.4.16（材料目录归一 + 收数地址归一化）

- `CRED_IMAGE_TAG` → **`v0.4.16-alpha`**，`CRED_WEB_IMAGE_TAG` 仍 `v0.2.8-alpha`。
- **接入命令自带 `--dir`**：页面里从下拉选（已用过的排前面）、存为认证系统的属性，
  签发时同时烘进脚本 —— `curl … | bash` 裸跑也能落对位置。
- **收数地址归一化**（cred 0.4.12/0.4.13）：只填 origin 时心跳是绿的，
  但推送是 `POST` 到地址**原样** → 每条都 404。现在四条写入口自动补收数路径，
  旧存储启动时迁移；推送 404 的报错会点名原因。

## [0.4.15-alpha] - 2026-11-04

### 变更：跟版 cred 0.4.15 / cred-web 0.2.8（材料目录成为认证系统的属性）

- `CRED_IMAGE_TAG` → **`v0.4.15-alpha`**，`CRED_WEB_IMAGE_TAG` → **`v0.2.8-alpha`**（demo peer 同包 `-example` 跟 cred 走）。
- **接入命令自带 `--dir`，且落点/角色都是可选组合**：部署栈里脚本的默认目录一定会被护栏拦下，
  而正确落点只有操作者知道。现在页面里从下拉选（已用过的排前面）、存为认证系统的属性，
  签发时同时烘进脚本 —— `curl … | bash` 裸跑也能落对位置。
- **收数地址归一化**（cred 0.4.12/0.4.13）：只填 origin（`https://host:3103`）时心跳是绿的，
  但推送是 `POST` 到地址**原样** → 每条都 404。现在四条写入口都会**自动补收数路径**，
  旧存储启动时迁移；推送 404 的报错会点名原因。
- 无需改现场配置；升级只换镜像 tag。

## [0.4.14-alpha] - 2026-11-04

### 变更：跟版 cred 0.4.12（收数地址归一化）

- `CRED_IMAGE_TAG` → **`v0.4.12-alpha`**（前端不动，仍 `v0.2.6-alpha`；demo peer 同包 `-example` 跟着动）。
- cred 0.4.12 修了一个会让推送**静默失败**的坑：收数地址只填 origin（`https://host:3103`）时，
  心跳是绿的（探活走 `origin + /healthz`），但推送是 `POST` 到地址**原样** → 每条都 404。
  现在三条写入路径（新建系统 / 接入上报 / 改收数地址）都会**自动补上收数路径**，
  已有存储里的旧值也会在启动时迁移；推送 404 的报错会点名原因。
- 无需改现场配置；升级只换镜像 tag。

## [0.4.13-alpha] - 2026-11-04

### 变更：跟版 cred 0.4.11（接入链路补端到端测试）

- `CRED_IMAGE_TAG` → **`v0.4.11-alpha`**（前端不动，仍 `v0.2.6-alpha`；
  demo peer 是同包 `-example`，跟着一起动）。
- cred 0.4.11 把「接入脚本」纳入**真跑**的端到端测试：起真 CA + 真 HTTP 服务，
  `curl` 取 `join.sh`、`bash` 执行，再核对落盘材料与 `cred.toml`。
- 修掉一处**静默失败**：bash 3.2 在有 EXIT trap 时，`set -u` 中途中断会以
  **退出码 0** 收场（脚本崩了却报成功）。现在用显式完成标记兜底，
  只有正常结束 / `die` / `--help` 才允许 0。
- 无需改现场配置；升级只换镜像 tag。

## [0.4.7-alpha] - 2026-11-03

### 变更：镜像源变量改名 `CRED_REGISTRY` → `WIST_SPC`

与 `wist-gateway-stack` **同名同义**：wist 系列镜像共用一个源前缀（值含命名空间）。

```yaml
WIST_SPC: ghcr.io/dayu-sec                    # 境外（默认）
WIST_SPC: dy-sec.tencentcloudcr.com/cloud     # 国内 TCR
```

- `sys/docker-compose.yml` 三处镜像引用、`.env.example`、`sys/merged_vars.yml` 一并跟改。
- **升级注意**：现场如果在自己 `values/<系统名>/sys_value.yml` 里覆盖了旧键，gops 会**静默接受**
  （旧键不再生效，镜像源默默退回 ghcr）。所以 `scripts/init-cred.sh` 增加了改名守卫：
  检测到 `CRED_REGISTRY` 仍在环境里就直接失败，并点名要改成 `WIST_SPC`。
- 新增 `dev/tests/vars-rename-guard.test.sh`（旧键拦住 / 不带旧键通过 / 三个文件里不得再出现旧名）。

## [0.4.6-alpha] - 2026-11-03

### 变更：跟版 cred 0.4.4（修正接入提示的语法）

- `CRED_IMAGE_TAG` → **`v0.4.4-alpha`**（前端不动，仍 `v0.2.3-alpha`）。
- 手动补参数时必须 `curl … | bash -s -- --config <file>`；正常路径是在页面「接入命令」面板里
  填接入落点，命令自带、不用参数。

## [0.4.5-alpha] - 2026-11-03

### 变更：跟版 cred 0.4.3 / cred-web 0.2.3

- `CRED_IMAGE_TAG` → **`v0.4.3-alpha`**，`CRED_WEB_IMAGE_TAG` → **`v0.2.3-alpha`**。
- 接入脚本可自带 `--config` / `--restart`：落点存在认证系统上（页面「接入命令」面板里填），
  签发时烘进脚本。**栈部署的服务（center / ingest）仍不要填** —— 它们的配置由本栈模板渲染。

## [0.4.4-alpha] - 2026-11-03

### 变更：把「写死的值」变成变量（对齐 `wist-gateway-stack` 的取值口径）

- **时区真的接线了**。`TZ` 以前只是一个变量：compose 不设 env、也不挂数据，所以它一次都没生效过。
  新增 `scripts/init-timezone.sh` + `TZ_RUNTIME_DIR`：localize 把宿主当前时区的 zone 文件
  复制进栈内，三个容器都用 `TZ=:/etc/tz-runtime/localtime` 读它 ——
  不挂宿主 `/etc/localtime`（会让 `gops sys perms` 去改系统文件权限），
  也不只写 `TZ=<zone 名>`（镜像没 tzdata 时 glibc 静默回 UTC）。与网关栈同一套做法。
- **`CRED_PUSH_TIMEOUT_SECONDS`**（默认 10）：渲染到 `[push].timeout_seconds`。
  跨区部署（互联网区 → 计算区）链路慢时调大；心跳是串行探的，调太大也会拖慢一轮。
- **`gops sys perms --apply` 进 localize 流程**。`sys-prj.yml` 早就声明了 `perms.services.cred`，
  流程注释也写着“随后由 `gops sys perms` 归位”，但**实际没有这一步** ——
  Linux 上新部署时 `configs/cred/state` 会停在部署账号名下，cred（999:999）写不进去。

### 修复：`.env.example` 漂移

- 它还钉着 `v0.3.0-alpha` / `v0.2.0-alpha`（落后两个发布）—— `gops sys update` **不会**重写它。
  已同步到当前值，并新增 `dev/tests/env-example-drift.test.sh` 逐键对比 `sys/merged_vars.yml`，
  以后再忘就不会静默漂了。

### 新增测试

- `dev/tests/init-timezone.test.sh`：产物是实体文件（非悬空链接）、二次跑幂等、
  未知 `TZ` 回落宿主 `/etc/localtime`、compose 真的把 `TZ` 与数据挂到容器。

## [0.4.3-alpha] - 2026-11-03

### 修复：接入登记打到 443（脚本里的地址丢端口）

- `CRED_IMAGE_TAG` → **`v0.4.2-alpha`**，`CRED_WEB_IMAGE_TAG` → **`v0.2.2-alpha`**。
- `sys/configs/web/nginx.conf.tpl`：`/enroll/` 的 `Host` 改为 `$http_host`（`$host` **不带端口**）。
  接入脚本里的登记地址是 cred 按 Host 拼的绝对地址，`$host` 会让它变成 `https://域名/enroll/…`，
  机器把 CSR 打到 443，拿到空体 404。
- `scripts/init-cred.sh` + `wist-cred.toml.tpl`：渲染 `[server].public_base_url`
  （`https://WEB_DOMAIN[:WEB_HOST_PORT]`，443 不写），配置优先于请求头。

### 升级注意

- 升完重新生成一条接入命令（旧券仍有效，但**旧脚本里的地址是错的**，重取即可）。

## [0.4.2-alpha] - 2026-11-03

### 修复：cred 容器起不来（`signing.key` 没挂）

- `0.4.0` 起 `[issue].signing_key` 是硬依赖，模板里写的是 `/wist-cred/identity/signing.key`，
  但 `sys/docker-compose.yml` **从来没挂过这个文件** —— cred 起来就报
  `read issue.signing_key /wist-cred/identity/signing.key: No such file or directory` 并重启循环。
- 补上只读挂载（与 CA-S 私钥同档，`0600`）。
- 升级提醒：**先 `gops sys localize` 再 `gops run start`** —— `localize` 会把缺的
  `identity/cred/signing.key` 补出来；直接 start 会让 docker 把不存在的源建成空目录。

## [0.4.1-alpha] - 2026-11-03

### 变更：接入面路径改名，入口白名单跟版

- `CRED_IMAGE_TAG` → **`v0.4.1-alpha`**，`CRED_WEB_IMAGE_TAG` → **`v0.2.1-alpha`**。
- `sys/configs/web/nginx.conf.tpl` 的免口令 location 从 `/onboarding/` 改为 `/enroll/`：
  机器面现在是 `GET /enroll/<券>/join.sh` + `POST /enroll/<券>/certificate`。
  旧的 `location /onboarding/` **不保留** —— 旧券寿命 ≤ 1h，升级窗口内失效可接受。
- 接入脚本不再要求 root（跟版 cred 0.4.1）：`dev/check-onboarding.sh`、`dev/check-peer-health.sh`
  里为了绕开 root 检查而伪造 `id` 的 shim 已删除。
- `dev/svc.sh` 同上；`./dev/svc.sh onboard` 打印的落点说明也同步更新。

### 升级注意

- cred 与 cred-web 两个镜像**同升**：新页面调新路径，旧后端只有旧路径。
- 已生成但尚未使用的接入命令会 404，回页面重新生成即可。

## [0.4.0-alpha] - 2026-11-03

### 新增：授权记录签名（跟版 cred 0.4.0）

- `CRED_IMAGE_TAG` → **`v0.4.0-alpha`**（旧版 `[issue]` 是 `deny_unknown_fields`，不跟版起不来）。
- `scripts/gen-pki.sh` 首次运行额外生成 `identity/cred/signing.key`（Ed25519）与公开的
  `signing.pub`（裸 32 字节 hex）；已存在不重签。
- `scripts/init-cred.sh` 在私钥存在但公钥缺失时补派生 `signing.pub`（demo peer 依赖它）。
- `sys/configs/cred/wist-cred.toml.tpl` 新增 `[issue].signing_key`：cred 对每条授权记录签名。
- 接入脚本同时下发 `issuer-signing.pub`；验证方的 `require_signature` 就是用它验。

### 升级注意

- **验证方要先升**（`wist-cred-peer 0.2`，先保持 `require_signature = false`），再升本栈，
  最后在验证方打开验签。
- 已接入的验证方需要重跑一次接入命令，补下 `issuer-signing.pub`。

## [0.3.3-alpha] - 2026-11-03

### 修复：新站点首次部署的引导路径

新导入的站点没有 `.wist/sec-value.yml`，`gops sys localize` 原本只回一句 gops 的
“声明了就必须存在”，不说该敲什么 —— 现场卡在这里时看不出下一步。

- `scripts/init-cred.sh` 先自己判文件在不在，不在就打印**可直接复制**的三段命令：
  属组前置（`usermod -aG 999` + `.wist` setgid）→ 生成 `cred_web_password` →
  `chmod 640` + `gops sec fix`。仍然**不**随机生成口令（会落终端/CI 日志）。
- 文件在但不合格（模式与 `secrets.mode` 不符等）时，把 **gops 的原文**透出来再补一句怎么修。
- README「起栈」第 2 步同步改成 0640 + 属组 + `gops sec fix`（之前写的还是过时的 `0600`）。
- 回归用例补充“引导提示必须包含 gops sec fix / cred_web_password / usermod -aG 999”。

## [0.3.2-alpha] - 2026-11-03

### 安全自查（三轮）修复

- **密钥文件改为 0640**（原 `0600`）：cred 以 uid 999 运行、靠**属组**读密钥，
  0600 在 Linux 上会让它读不到（fail-closed 但服务起不来）。与 `wist-center-stack` 同一口径；
  `gops sec list` 会在 mode 与声明不符时直接报错，`gops sec fix` 只改 mode、不改属组。
  **升级注意**：Linux 现场需 `usermod -aG 999 <部署账号>`，`.wist` 用 setgid（2770），
  然后 `gops sec fix`（或等 localize）把 mode 收敛到 0640。
- **`/onboarding/` 关掉 access_log**：一次性券在 URL 里，不能进日志（日志会落盘 / 被采集）。
- **`server_tokens off`**：不再在 `Server` 头 / 错误页透漏 nginx 版本。
- 删掉一条失效的 `auth_basic off`（入口早就不做 basic auth 了）。

### 已知与接受（不修）

- 页面口令**没有失败锁定**：它是部署方设置的 24 hex（≥96 bit），在线猜测不可行；
  401 风暴的来源（页面拿错口令轮询）已在协议上麦掉。
- `web` 容器仍是 **root**（nginx 官方镜像要绑 443）；与其它栈一致。
- crednet **不限制出网**：cred 需要向外推送摘要（mTLS 到各认证系统）。

## [0.3.1-alpha] - 2026-11-03

### 新增：本仓有了发布流水线（部署包 + GitHub Release）

以前只有 tag，没有制品 —— 对照 `wist-ingest-stack` 的 `release.yml` 补齐：

- **verify**：`docker compose --env-file .env.example config`（新增入库的 `.env.example`，
  用产品默认值）+ `./dev/lint.sh` + `dev/tests/*.test.sh`。
- **package**：`git archive` 出 `wist-cred-stack-<tag>.tar.gz`（只含 git 跟踪内容，无 --prefix）。
- **release**：发 GitHub Release（`generate_release_notes`）；配了 `COS_BUCKET` 时同步 JSON 到 COS。
- 新增 `dev/lint.sh`：与 `wist-gateway-stack` 同一条口径（`-S warning` + `SC2006` 两道）。
  顺手修了 `dev/check-peer-health.sh` 里一处 unicode 引号（SC1111）。

### 文档

- README：「阶段与边界」里两条过时描述（推送“未实现”、本服务“不持密钥”）按现状改写；
  新增「发布」一节（tag → verify/package/release）。

## [0.3.0-alpha] - 2026-11-03

### 组件跟版

- `CRED_IMAGE_TAG` → `v0.3.0-alpha`（`CRED_WEB_IMAGE_TAG` 仍是 `v0.2.0-alpha`，前端未变）。

### Changed：示例验证方不再由本栈构建

- `peer-demo` 改成引 **`${CRED_REGISTRY}/wist-cred:${CRED_IMAGE_TAG}-example`** ——
  示例验证方的源码已回到 `wist-cred` 仓（`examples/peer_example.rs`），镜像由那边的
  release 流水线一起产出。本栈删掉 `dev/peer-example/`、删掉 `build:` / `pull_policy: build`
  与 `PEER_RUST_IMAGE` / `PEER_RUNTIME_IMAGE` 两个变量。
- 原因：生态惯例是**一个镜像一个二进制**、**stack 只引 tag 不建镜像**；之前的实作还引入了
  docker.io 基础镜像、glibc 版本匹配这类与业务无关的故障面。
- 开发态不受影响：`./dev/svc.sh start peer` 会用 `wist-cred` 源码 `cargo run --example peer_example`。

### 升级注意

- demo peer 需要 `wist-cred` ≥ 0.3.0（那一版才发 `-example` 镜像）。
- 之前本地 build 过 `wist-cred-peer-example:local` 的机器可以删掉它。

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
