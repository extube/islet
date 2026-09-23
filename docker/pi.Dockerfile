# docker/pi.Dockerfile
#
# Alpine-based image providing the pi coding agent (@earendil-works/pi-coding-agent).
# Node.js for Alpine (musl-based).
#
# Build:
#   docker build -f docker/pi.Dockerfile -t islet/pi:latest .
#
# Run:
#   docker run --rm -it islet/pi:latest

FROM node:24-alpine

LABEL org.opencontainers.image.title="islet-pi" \
      org.opencontainers.image.description="pi coding agent on Alpine" \
      org.opencontainers.image.source="https://github.com/earendil-works/pi-coding-agent"

# Necessary environment for the agent:
#   bash              - agent shell
#   ca-certificates   - TLS trust
#   git, ripgrep      - agent repository interaction and search
RUN apk add --no-cache bash ca-certificates git ripgrep

RUN npm install -g --ignore-scripts @earendil-works/pi-coding-agent

WORKDIR /workspace

ENTRYPOINT ["pi"]
