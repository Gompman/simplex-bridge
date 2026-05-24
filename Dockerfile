FROM ubuntu:24.04
LABEL org.opencontainers.image.source="https://github.com/libre-7/simplex-bridge"
LABEL org.opencontainers.image.description="SimpleX Chat bot daemon — WebSocket API for Hermes Agent and other bots"
LABEL org.opencontainers.image.licenses="GPL-3.0"

# SimpleX Chat uses the SMP protocol — no persistent user IDs, fully private
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates curl iproute2 python3 python3-pip socat tzdata && \
    pip3 install --break-system-packages websockets && \
    rm -rf /var/lib/apt/lists/* /root/.cache/pip

# Install simplex-chat CLI binary (static Haskell binary, no runtime deps)
RUN curl -fsSL -o /usr/local/bin/simplex-chat \
        "https://github.com/simplex-chat/simplex-chat/releases/download/v6.5.1/simplex-chat-ubuntu-24_04-x86_64" && \
    chmod +x /usr/local/bin/simplex-chat && \
    simplex-chat --version

VOLUME ["/data"]
EXPOSE 5225

ENV SIMPLEX_DISPLAY_NAME="Simplex Bridge" \
    SIMPLEX_AUTO_ACCEPT=true \
    SIMPLEX_FILES_ENABLED=true \
    SIMPLEX_MARK_READ=true \
    SIMPLEX_TOR=false \
    SIMPLEX_SOCAT_PORT="" \
    TZ=UTC

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]

STOPSIGNAL SIGTERM

# Health check: verify WebSocket port is listening
HEALTHCHECK --start-period=10s --interval=30s --timeout=5s --retries=3 \
  CMD ss -tlnp 2>/dev/null | grep -q :5225 || exit 1
