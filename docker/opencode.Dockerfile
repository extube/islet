# docker/opencode.Dockerfile
#
# Alpine-based image providing the opencode agent harness.
# Used by islet to run opencode in an isolated container.
#
# Build:
#   docker build -f docker/opencode.Dockerfile -t islet/opencode:latest .
#
# Run:
#   docker run --rm -it islet/opencode:latest

FROM alpine:latest

ARG OPENCODE_VERSION=latest

LABEL org.opencontainers.image.title="islet-opencode" \
      org.opencontainers.image.description="opencode agent harness on Alpine" \
      org.opencontainers.image.source="https://github.com/anomalyco/opencode"

# Necessary environment for the agent and the installer:
#   bash      - opencode install script and agent shell
#   curl/wget - installer downloads, agent HTTP needs
#   git       - agent repository interaction
#   ca-certificates, tzdata - TLS trust and timezone data
#   jq, tar, unzip, ripgrep, fd - tools the agent commonly relies on
RUN apk add --no-cache \
      bash \
      curl \
      wget \
      git \
      ca-certificates \
      tzdata \
      jq \
      tar \
      unzip \
      ripgrep \
      fd

# Install the opencode binary.
#   SHELL must be set: the installer expands ${SHELL:?} (unset in the image).
#   --skip-colors: keep installer output readable in build logs.
#   --no-modify-path: PATH is set explicitly below.
# The installer places the binary in /root/.opencode/bin.
ENV SHELL=/bin/sh
RUN curl -fsSL https://opencode.ai/install | bash -s -- \
      --no-modify-path ${OPENCODE_VERSION:+--version ${OPENCODE_VERSION}}

ENV PATH="/root/.opencode/bin:${PATH}"

# Config and data locations mount points (see islet.sh):
#   /root/.config/opencode  - agent config (mounted from ~/.config/opencode)
#   /root/.local/share/opencode - agent data, sessions and auth
RUN mkdir -p /root/.config/opencode /root/.local/share/opencode /workspace

WORKDIR /workspace

ENTRYPOINT ["opencode"]
