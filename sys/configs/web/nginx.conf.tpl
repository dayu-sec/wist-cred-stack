# wist-cred-web 站点配置**模板**（handlebars，由 localize 渲染）。
# src: 本文件（sys/configs/web/nginx.conf.tpl）
# dst: configs/web/nginx.conf（compose 挂到 /etc/nginx/conf.d/default.conf）
# 渲染值：configs/web/nginx.value.json（scripts/init-cred.sh 生成）
#
# 职责：**终止 TLS** + 托管前端静态产物 + SPA 深链回退 + 把 /api 反代到 cred。
#
# ⚠ 这一跳是本栈唯一的人机入口，也是唯一写操作者头的地方：
#   · 认证在 nginx（阶段一 basic auth；将来接用户中心 / 钉钉 OIDC 时换这一层，下游不动）；
#   · `x-wist-operator` **只由这里写**，客户端自带的同名头不会透传（nginx 只发 set 过的值）；
#   · cred 侧还会用 peer IP 白名单二次确认"请求确实来自这个 nginx"。

server {
    listen 443 ssl;
    server_name {{web_domain}};

    ssl_certificate     /certs/server.crt;
    ssl_certificate_key /certs/server.key;
    ssl_protocols       TLSv1.2 TLSv1.3;

    root /usr/share/nginx/html;
    index index.html;

    # 静态资源 + SPA 深链回退：找不到实体文件就交给前端路由。
    location / {
        try_files $uri $uri/ /index.html;
    }

    location /api/ {
        # 阶段一的"人是谁"：由入口认证，nginx 只把结果写进注入头。
        auth_basic           "wist-cred";
        auth_basic_user_file /etc/nginx/htpasswd;

        # 明文 HTTP 到 cred（容器内 8443）；cred 不对宿主发布端口。
        proxy_pass         http://{{cred_ip}}:8443;
        proxy_http_version 1.1;
        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;

        # 操作者头：**只发这里 set 的值**，客户端带来的同名头一律不转发。
        proxy_set_header   x-wist-operator   $remote_user;
    }

    # 一次性接入脚本 + 登记：**取/交它们的是验证方 X（机器），不是人**，所以没有 basic auth。
    # 授权依据是 URL 里那张一次性券（分钟级 TTL；取脚本可重取，登记时兑现即废），
    # 再加上 cred 侧的 peer IP 白名单（这条跳仍然只可能来自本 nginx）。
    # 这也意味着：X 必须能访问到本 entry（一次性，之后全靠 mTLS 直连）。
    location /onboarding/ {
        auth_basic off;

        proxy_pass         http://{{cred_ip}}:8443;
        proxy_http_version 1.1;
        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
        # 脚本里有私钥：不让任何中间层缓存。
        proxy_no_cache     1;
        add_header         Cache-Control "no-store" always;
    }
}
