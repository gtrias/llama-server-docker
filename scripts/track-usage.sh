#!/bin/bash
# Track model usage - Record timestamp for a specific model
# Usage: ./scripts/track-usage.sh <alias>

set -e

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

# Record current timestamp
current_time=$(date +%s)
mkdir -p "$PROJECT_DIR/.model_last_used"
echo "${current_time}" > "$PROJECT_DIR/.model_last_used/${alias}"

echo "Recorded usage for model: ${alias}"
echo "Timestamp: ${current_time} ($(date -d @${current_time}))"
echo ""

# Show last used times
echo "All model usage times:"
echo "======================"
for model in qwen-code qwen35 glm; do
    if [ -f "$PROJECT_DIR/.model_last_used/${model}" ]; then
        last_used=$(cat "$PROJECT_DIR/.model_last_used/${model}")
        idle_seconds=$(($(date +%s) - last_used))
        idle_minutes=$((idle_seconds / 60))
        
        if [ $idle_seconds -lt 60 ]; then
            idle_str="${idle_seconds}s"
        else
            idle_str="${idle_minutes}m"
        fi
        
        echo "  ${model}: last used ${idle_str} ago"
    else
        echo "  ${model}: never used"
    fi
done