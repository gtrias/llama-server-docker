#!/bin/bash
# Unload a specific model from memory
# Usage: ./scripts/unload-model.sh <alias>

set -e

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
API_URL="${API_URL:-http://localhost:11434}"

alias="${1:-}"

if [ -z "$alias" ]; then
    echo "Usage: $0 <alias>"
    echo ""
    echo "Available aliases:"
    echo "  qwen-code - Qwen3 Coder Next"
    echo "  qwen35    - Qwen3.5 35B A3B (Q4_K_M)"
    echo "  glm       - GLM-4.7 Flash REAP"
    exit 1
fi

echo "Unloading model: ${alias}"

# Check if model is loaded
status=$(curl -s "${API_URL}/v1/models" 2>/dev/null | jq -r ".data[]? | select(.id == \"$alias\") | .status.value" || echo "unknown")

if [ "$status" = "unloaded" ]; then
    echo "Model ${alias} is already unloaded!"
    exit 0
elif [ "$status" = "unknown" ]; then
    echo "Warning: Could not determine model status. Proceeding with unload attempt."
fi

# Note: llama.cpp may not support manual unloading via API
# This depends on the server version and configuration
# The unload would typically happen automatically via:
# 1. LRU eviction when max_models reached
# 2. Manual intervention via WebUI
# 3. Server restart

echo ""
echo "To unload this model, you have several options:"
echo ""
echo "Option 1: Use the WebUI"
echo "  Visit http://localhost:11434/"
echo "  Navigate to the Models section and click 'Unload' next to ${alias}"
echo ""
echo "Option 2: Restart the server (unloads all models)"
echo "  docker-compose restart llama-server"
echo ""
echo "Option 3: Use auto-offload daemon"
echo "  Start: ./scripts/model-manager.sh start"
echo "  The daemon will unload idle models after timeout period"
echo ""
echo "Current model status:"
curl -s "${API_URL}/v1/models" 2>/dev/null | jq '.data[] | select(.id=="'${alias}'")' || echo "Could not fetch model status"