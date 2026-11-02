# Changelog

## [Unreleased]

### Added

- **骨架**：`sys/docker-compose.yml`（cred + web 两个服务、专用 bridge 网段、cred 不对宿主发布端口）
- `sys/setting/vars.yml`：镜像、网段与固定 IP、宿主入口、签发上限、推送目标占位
- `sys/configs/cred/wist-cred.toml.tpl`：`listen_addr` 用容器私网 IP、`trusted_peers` 只放 web（S1 / S3）
- `sys/configs/web/nginx.conf.tpl`：终止 TLS + 静态 + `/api` 反代 + **只由 nginx 写**操作者头
- `scripts/init-cred.sh`：渲染值 + 站点证书 + bootstrap htpasswd（全幂等）
- `scripts/ensure-cred-server-cert.sh`：自签站点证书（带 SAN，LibreSSL 兼容）
- `sys-prj.yml`：`identity/` 进 contract、`configs/` 进 backup、cred 以 999:999 运行的 perms
- `dev/svc.sh`：开发态入口 —— 组件 `cred` / `web`，`start` / `stop` / `restart` / `status` / `logs` / `token` / `verify` / `demo`
  （本地进程，不进 docker、不做 TLS；`verify`/`demo` 直接跑 `wist-auth` 的真实验证实现）
  - `start` 默认起全部：cred :18443 + web（vite）:5174；`start web` / `restart cred` 可单点
  - `start` 成功后打印页面地址、API 端点与 curl 示例
  - `status` 同时报两个组件的健康与表里条目数
  - 不依赖 bash 4（macOS 自带 3.2 可跑）
