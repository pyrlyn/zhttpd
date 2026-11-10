# zhttpd — Zig HTTP server. Built without TLS for the container image
# (plain HTTP on 8080). See README for GHCR tag mapping.
FROM debian:bookworm-slim AS build
ARG TARGETARCH
ARG ZIG_VERSION=0.17.1
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl xz-utils \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /opt/zig
RUN zarch="$TARGETARCH" \
    && case "$zarch" in amd64) zarch=x86_64 ;; arm64) zarch=aarch64 ;; esac \
    && curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-linux-${zarch}-${ZIG_VERSION}.tar.xz" \
    | tar -xJ --strip-components=1
WORKDIR /src
COPY build.zig build.zig.zon ./
COPY src ./src
RUN /opt/zig/zig build -Doptimize=ReleaseFast -Dtls=false

FROM debian:bookworm-slim
LABEL org.opencontainers.image.source="https://github.com/pyrlyn/zhttpd" \
      org.opencontainers.image.title="zhttpd" \
      org.opencontainers.image.description="Zig HTTP server"
RUN mkdir -p /var/www/zhttpd /var/lib/zhttpd/logs
COPY --from=build /src/zig-out/bin/zhttpd /usr/local/bin/zhttpd
COPY deploy/nginx.conf /etc/zhttpd/nginx.conf
COPY deploy/index.html /var/www/zhttpd/index.html
EXPOSE 8080
WORKDIR /var/lib/zhttpd
CMD ["zhttpd", "-c", "/etc/zhttpd/nginx.conf"]
