ARG RUNTIME_PLATFORM=linux/amd64

FROM --platform=$RUNTIME_PLATFORM rust:1.88-bookworm AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    build-essential \
    ca-certificates \
    curl \
    libssl-dev \
    pkg-config \
    tar \
    unzip \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY . .

RUN chmod +x \
    /app/start.sh \
    /app/scripts/*.sh \
    /app/fiber-bundle/deploy/*.sh

RUN PROJECT_BIN_DIR=/app/bin FORCE_REINSTALL_BINARIES=y /app/scripts/install-binaries.sh

RUN cargo build --release

RUN install -Dm755 /app/target/release/ckb-chat /app/bin/ckb-chat

FROM --platform=$RUNTIME_PLATFORM debian:bookworm-slim AS runtime

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    curl \
    lsof \
    netcat-openbsd \
    procps \
    tar \
    unzip \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

ENV PATH="/app/bin:${PATH}" \
    APP_HOST="0.0.0.0" \
    PORT="3000" \
    DEMO_PORT="3000"

COPY --from=builder /app/start.sh /app/start.sh
COPY --from=builder /app/scripts /app/scripts
COPY --from=builder /app/static /app/static
COPY --from=builder /app/fiber-bundle /app/fiber-bundle
COPY --from=builder /app/bin /app/bin

RUN chmod +x \
    /app/start.sh \
    /app/scripts/*.sh \
    /app/fiber-bundle/deploy/*.sh

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=10s --start-period=20m --retries=5 \
  CMD curl -fsS "http://127.0.0.1:${PORT:-3000}/api/ready" || exit 1

ENTRYPOINT ["./start.sh"]
