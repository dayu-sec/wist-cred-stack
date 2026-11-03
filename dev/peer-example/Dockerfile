# ===========================================================================
# 演示用验证方（peer-example）—— 只在 `COMPOSE_PROFILES=demo` 时构建/启动
#
# 这不是 cred 的一部分，而是"另一个系统"：收 register/revoke、自己存摘要、心跳。
# 证书在 localize 阶段由宿主签好（SAN = 服务名 peer-demo），挂载进容器。
# ===========================================================================

FROM rust:1-slim AS builder
WORKDIR /app

# 先用空 main 拉依赖，让这层能缓存（改代码不必重下 crates）。
COPY Cargo.toml Cargo.lock ./
RUN mkdir -p src && echo 'fn main() {}' > src/main.rs \
    && cargo build --release \
    && rm -rf src target/release/deps/peer_example* target/release/peer-example

COPY src ./src
RUN cargo build --release

FROM debian:bookworm-slim

LABEL org.opencontainers.image.source="https://github.com/dayu-sec/wist-cred-stack"
LABEL org.opencontainers.image.description="Demo verifier for wist-cred (not part of the credential service)"
LABEL org.opencontainers.image.licenses="Apache-2.0"

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /app/target/release/peer-example /usr/local/bin/peer-example

# 只收 cred 的推送，不对宿主发布端口。
EXPOSE 19443

ENTRYPOINT ["peer-example"]
CMD []
