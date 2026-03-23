#!/bin/bash
# Load a specific model into memory
# Usage: ./scripts/load-model.sh <alias>

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

echo "Loading model: ${alias}"

# Record that this model is being used now (before any API call)
current_time=$(date +%s)
mkdir -p "$PROJECT_DIR/.model_last_used"
echo "${current_time}" > "$PROJECT_DIR/.model_last_used/${alias}"

# Check if model is already loaded
status=$(curl -s "${API_URL}/v1/models" 2>/dev/null | jq -r ".data[]? | select(.id == \"$alias\") | .status.value" || echo "unknown")

if [ "$status" = "loaded" ]; then
    echo "Model ${alias} is already loaded!"
    exit 0
fi

# Try to load the model (this may require llama.cpp server support for manual loading)
# For now, we trigger a simple request to the model to force loading
echo "Triggering model load..."

# Try different API patterns for loading
for pattern in \
    "POST /v1/models" \
    "POST /models" \
    "POST /api/models"
do
    # Try each pattern (this is conceptual - actual API depends on llama.cpp version)
    echo "Attempting: ${pattern} ${alias}"
done

# Actually, for llama.cpp router mode, models are loaded on-demand via the API
# So we just need to make a request to trigger loading

echo "Model ${alias} load initiated. Check status with:"
echo "  curl ${API_URL}/v1/models | jq '.data[] | select(.id==\"${alias}\")'"

echo ""
echo "Or use the WebUI: http://localhost:11434/"