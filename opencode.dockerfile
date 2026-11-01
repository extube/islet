# opencode agent harness — Alpine, runtime setup baked at build time.
FROM alpine:latest

RUN apk add --no-cache \
      bash curl wget jq tar unzip git ripgrep ca-certificates tzdata

# Install the opencode binary. The installer needs bash (not busybox sh) —
# installed by the apk line above.
ENV SHELL=/bin/sh
RUN curl -fsSL https://opencode.ai/install | bash
ENV PATH="/root/.opencode/bin:${PATH}"

RUN mkdir -p /workspace /root/.config/opencode
WORKDIR /workspace

ENTRYPOINT ["opencode"]
