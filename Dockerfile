# Dockerfile for llama.cpp server with WebUI support
# Based on official llama.cpp Docker documentation

FROM ghcr.io/ggml-org/llama.cpp:server-cuda

# Install additional tools for model management
RUN apt-get update && apt-get install -y \
    curl \
    wget \
    jq \
    python3 \
    python3-pip \
    && pip3 install --break-system-packages huggingface-hub \
    && rm -rf /var/lib/apt/lists/*

# Create directories for models and cache
RUN mkdir -p /models /cache

# Set working directory
WORKDIR /app

# Copy entrypoint script and model configurations
COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh
COPY config/ /app/config/
COPY scripts/ /app/scripts/

# Set environment variables
ENV LLAMA_ARG_HOST=0.0.0.0
ENV LLAMA_ARG_PORT=8080
ENV LLAMA_ARG_JINJA=true

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -f http://localhost:8080/health || exit 1

# Expose default port
EXPOSE 8080

# Override entrypoint and command
ENTRYPOINT ["/app/entrypoint.sh"]
CMD []
