# docker/hermes.Dockerfile
#
# Alpine-based image providing the hermes agent harness (Nous Research).
# Used by islet to run hermes in an isolated container.
#
# Build:
#   docker build -f docker/hermes.Dockerfile -t islet/hermes:latest .
#
# Run:
#   docker run --rm -it islet/hermes:latest

FROM alpine:latest

LABEL org.opencontainers.image.title="islet-hermes" \
      org.opencontainers.image.description="hermes agent harness on Alpine" \
      org.opencontainers.image.source="https://github.com/NousResearch/hermes-agent"

# Necessary environment for the agent and the installer:
#   bash              - installer and agent shell
#   curl/wget         - installer downloads, agent HTTP needs
#   git               - agent repository interaction
#   ca-certificates, tzdata - TLS trust and timezone data
#   jq, tar, unzip, ripgrep - tools the agent commonly relies on
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
      ripgrep

# Install the hermes agent.
# The installer places the binary in ~/.hermes/bin (PATH set below).
RUN curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash

ENV PATH="/root/.hermes/bin:${PATH}"

WORKDIR /workspace

ENTRYPOINT ["hermes"]
