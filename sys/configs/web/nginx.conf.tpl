# wist-cred-web 站点配置**模板**（handlebars，由 localize 渲染）。
# src: 本文件（sys/configs/web/nginx.conf.tpl）
# dst: configs/web/nginx.conf（compose 挂到 /etc/nginx/conf.d/default.conf）
# 渲染值：configs/web/nginx.value.json（scripts/init-cred.sh 生成）
#
# 职责：**终止 TLS** + 托管前端静态产物 + SPA 深链回退 + 把 /api 反代到 cred。
#
# ⚠ 这一跳**不碰身份**：
#   · 页面口令由页面自己输、带在 `Authorization: Bearer` 上，由 cred 自己验（`mode = token`）；
#   · 所以这里**不写** `x-wist-operator`、不做 `auth_basic`，也不改写 Authorization；
#   · cred 侧还有 peer IP 白名单（`trusted_peers`）确认“请求确实来自这个 nginx”；
#   · 将来接用户中心 / 钉钉时换的是 cred 的认证分支（`mode = oidc`），这一层仍然不动。

server {
    listen 443 ssl;
    server_name {{web_domain}};

    # 不回版本号：错误页 / Server 头里别透漏 nginx 版本（指纹面越小越好）。
    server_tokens off;

    ssl_certificate     /certs/server.crt;
    ssl_certificate_key /certs/server.key;
    ssl_protocols       TLSv1.2 TLSv1.3;

    root /usr/share/nginx/html;
    index index.html;

    # 静态资源 + SPA 深链回退：找不到实体文件就交给前端路由。
    # **这里不做认证**：人机面的口令在页面里输，由 cred 自己验（`mode = token`）。
    # 入口只负责 TLS / 静态 / 反代 —— “谁能进”是产品的事，不是反代的事。
    location / {
        try_files $uri $uri/ /index.html;
    }

    location /api/ {
        # 明文 HTTP 到 cred（容器内 8443）；cred 不对宿主发布端口。
        # 凭据（`Authorization: Bearer <页面口令>`）是**页面自己带的**，
        # 这里原样透传，不注入、不改写 —— 否则“是谁在操作”又变成了反代的结论。
        proxy_pass         http://{{cred_ip}}:8443;
        proxy_http_version 1.1;
        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
    }

    # 接入脚本 + 兑换证书：**取/交它们的是验证方 X（机器）**，不需要页面口令。
    # 授权依据是 URL 里那张一次性券（分钟级 TTL；取 join.sh 可重取，兑换 certificate 时即废），
    # 再加上 cred 侧的 peer IP 白名单（这条跳仍然只可能来自本 nginx）。
    # 这也意味着：X 必须能访问到本 entry（一次性，之后全靠 mTLS 直连）。
    location /enroll/ {
        # 券在 URL 里 = 一把有期限的一次性凭据。**不能写进访问日志**：
        # 日志会落盘、被采集、被转发，拿到日志的人就能在兑换前抢用这张券。
        access_log off;

        proxy_pass         http://{{cred_ip}}:8443;
        proxy_http_version 1.1;
        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
        # 响应是接入脚本（只有公开材料 + 券本身）：不让任何中间层缓存这条带券的 URL。
        proxy_no_cache     1;
        add_header         Cache-Control "no-store" always;
    }
}
