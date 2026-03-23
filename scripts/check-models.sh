#!/bin/bash
# Check status of all configured models
# Usage: ./scripts/check-models.sh

set -e

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
API_URL="${API_URL:-http://localhost:11434}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}=== Model Status Check ===${NC}"
echo "API URL: ${API_URL}"
echo ""

# Try to fetch models
models_json=$(curl -s "${API_URL}/v1/models" 2>/dev/null)

if [ -z "$models_json" ]; then
    echo -e "${RED}Error: Could not connect to API${NC}"
    echo "Make sure the llama-server container is running:"
    echo "  docker-compose ps"
    exit 1
fi

# Parse and display model status
echo "Configured Models:"
echo "=================="
echo ""

for alias in qwen-code qwen35 glm; do
    status=$(echo "$models_json" | jq -r ".data[]? | select(.id == \"$alias\") | .status.value" || echo "not found")
    
    case "$status" in
        loaded)
            echo -e "${GREEN}✓${NC} ${alias}: ${GREEN}LOADED${NC}"
            
            # Check last used time
            if [ -f "$PROJECT_DIR/.model_last_used/${alias}" ]; then
                last_used=$(cat "$PROJECT_DIR/.model_last_used/${alias}")
                current_time=$(date +%s)
                idle_seconds=$((current_time - last_used))
                idle_minutes=$((idle_seconds / 60))
                
                if [ $idle_seconds -lt 60 ]; then
                    idle_str="${idle_seconds}s"
                else
                    idle_str="${idle_minutes}m"
                fi
                
                echo "   Last used: ${idle_str} ago"
            else
                echo "   Last used: unknown"
            fi
            ;;
        unloaded)
            echo -e "○ ${alias}: Unloaded"
            ;;
        *)
            echo -e "? ${alias}: ${status}"
            ;;
    esac
    echo ""
done

# Show memory summary
echo ""
echo "Memory Summary:"
echo "=============="

# Get GPU memory info if available
if command -v nvidia-smi &> /dev/null; then
    echo ""
    nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader | while read line; do
        echo "GPU: $line"
    done
fi

# Show container stats
echo ""
echo "Container stats:"
docker stats llama-server --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}" 2>/dev/null || echo "Could not fetch container stats"

echo ""
echo "To manage models manually:"
echo "  Load:   ./scripts/load-model.sh <alias>"
echo "  Unload: ./scripts/unload-model.sh <alias>"
echo ""
echo "To enable auto-offload:"
echo "  ./scripts/model-manager.sh start"