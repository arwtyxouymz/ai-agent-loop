FROM node:20-slim

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    curl \
    jq \
    gettext-base \
    && rm -rf /var/lib/apt/lists/*

# Install Claude Code CLI
RUN npm install -g @anthropic-ai/claude-code

# Create non-root agent user with fixed UID
ARG AGENT_UID=1001
RUN useradd -u ${AGENT_UID} -m -s /bin/bash agent

# Create working directories with agent ownership
RUN mkdir -p /workspace /config \
    && chown -R agent:agent /workspace /config

# Copy entrypoint
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Switch to non-root user
USER agent
WORKDIR /workspace

ENTRYPOINT ["/entrypoint.sh"]
