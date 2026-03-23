#!/bin/bash

# llama-server Docker Entrypoint
# Uses router mode with curated model presets

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_config() {
    echo -e "${BLUE}[CONFIG]${NC} $1"
}

# Get configuration from environment
HOST=${LLAMA_ARG_HOST:-"0.0.0.0"}
PORT=${LLAMA_ARG_PORT:-"8080"}
MODELS_DIR=${LLAMA_ARG_MODELS_DIR:-""}
MODELS_PRESET=${LLAMA_ARG_MODELS_PRESET:-"/config/models.ini"}
MODELS_MAX=${LLAMA_ARG_MODELS_MAX:-"4"}
MODELS_AUTOLOAD=${LLAMA_ARG_MODELS_AUTOLOAD:-"true"}
NGP_LAYERS=${LLAMA_ARG_N_GPU_LAYERS:-"-1"}
FLASH_ATTN=${LLAMA_ARG_FLASH_ATTN:-"on"}
JINJA=${LLAMA_ARG_JINJA:-"true"}

# Display configuration
log_info "Starting llama-server in router mode..."
log_config "  Host: $HOST:$PORT"
log_config "  Preset file: $MODELS_PRESET"
log_config "  Max models: $MODELS_MAX"
log_config "  Auto-load: $MODELS_AUTOLOAD"
log_config "  GPU layers: $NGP_LAYERS (-1 = all)"
log_config "  Flash attention: $FLASH_ATTN"
log_config "  Timeout: ${LLAMA_ARG_TIMEOUT:-120}s"

if [ -n "$MODELS_DIR" ]; then
    log_config "  Models dir discovery: enabled ($MODELS_DIR)"
else
    log_config "  Models dir discovery: disabled (preset-only)"
fi

log_info ""
log_info "Models defined in preset file will be loaded on-demand."
log_info ""

# Check if models directory exists and has content (only if discovery is enabled)
if [ -n "$MODELS_DIR" ]; then
    if [ ! -d "$MODELS_DIR" ]; then
        log_info "Models directory not found: $MODELS_DIR"
        log_info "Creating directory..."
        mkdir -p "$MODELS_DIR"
    fi

    MODEL_COUNT=$(find "$MODELS_DIR" -name "*.gguf" 2>/dev/null | wc -l)
    log_info "Found $MODEL_COUNT GGUF model file(s) in discovery directory"
fi

# Auto-download missing models
AUTO_DOWNLOAD=${LLAMA_AUTO_DOWNLOAD:-"true"}
if [ "$AUTO_DOWNLOAD" = "true" ] && [ -f /scripts/auto-download.sh ]; then
    log_info "Checking for missing models..."
    bash /scripts/auto-download.sh "$MODELS_PRESET" "/root/.cache/llama.cpp"
    log_info ""
fi

# Strip auto-download keys from preset before passing to llama-server
# (llama-server doesn't understand hf-repo, hf-file, mmproj-hf-file)
CLEAN_PRESET="/tmp/models-clean.ini"
sed '/^[[:space:]]*hf-repo[[:space:]]*=/d;/^[[:space:]]*hf-file[[:space:]]*=/d;/^[[:space:]]*mmproj-hf-file[[:space:]]*=/d' "$MODELS_PRESET" > "$CLEAN_PRESET"
MODELS_PRESET="$CLEAN_PRESET"

# Build llama-server command with preset file
CMD="/app/llama-server"
TIMEOUT=${LLAMA_ARG_TIMEOUT:-"120"}

CMD_ARGS=(
    "--host" "$HOST"
    "--port" "$PORT"
    "--models-preset" "$MODELS_PRESET"
    "--models-max" "$MODELS_MAX"
    "--models-autoload"
    "--n-gpu-layers" "$NGP_LAYERS"
    "--timeout" "$TIMEOUT"
)

# Optional directory discovery
if [ -n "$MODELS_DIR" ]; then
    CMD_ARGS+=("--models-dir" "$MODELS_DIR")
fi

# Add optional flags - flash-attn needs explicit value
if [ "$FLASH_ATTN" = "on" ]; then
    CMD_ARGS+=("--flash-attn" "on")
fi

if [ "$JINJA" = "true" ]; then
    CMD_ARGS+=("--jinja")
fi

# Start llama-server
log_info "Initializing llama-server..."
exec "$CMD" "${CMD_ARGS[@]}"
