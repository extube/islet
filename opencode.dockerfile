# opencode agent harness — Alpine, runtime setup baked at build time.
FROM alpine:latest

RUN apk add --no-cache \
      bash curl wget jq tar unzip git ripgrep ca-certificates tzdata

# Install the opencode binary.
# SHELL must be set — the installer expands /usr/bin/bash (unset under busybox).
ENV SHELL=/bin/sh
RUN curl -fsSL https://opencode.ai/install | sh
ENV PATH="/root/.opencode/bin:${PATH}"

RUN mkdir -p /workspace /root/.config/opencode
WORKDIR /workspace

ENTRYPOINT ["opencode"]
