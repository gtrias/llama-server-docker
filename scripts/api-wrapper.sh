#!/bin/bash
# API Wrapper - Intercepts API calls to track model usage timestamps
# Usage: ./scripts/api-wrapper.sh <curl_command>
#
# This script wraps your API calls to track when each model is used,
# which enables the auto-offload system to work correctly.

set -e

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
API_URL="${API_URL:-http://localhost:11434}"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }

# Extract model name from curl command or arguments
extract_model() {
    local model=""

    # Try to extract model from various curl command patterns
    # Pattern 1: --model qwen
    if [[ "$*" =~ --model[[:space:]]+([^[:space:]]+) ]]; then
        model="${BASH_REMATCH[1]}"
    # Pattern 2: "model": "qwen"
    elif [[ "$*" =~ \"model\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
        model="${BASH_REMATCH[1]}"
    # Pattern 3: 'model': 'qwen'
    elif [[ "$*" =~ .model.[[:space:]]*:[[:space:]]*.([^[:space:]]+). ]]; then
        model="${BASH_REMATCH[1]}"
    fi

    echo "$model"
}

# Record model usage
record_usage() {
    local model="$1"
    local current_time=$(date +%s)
    
    if [ -n "$model" ]; then
        mkdir -p "$PROJECT_DIR/.model_last_used"
        echo "${current_time}" > "$PROJECT_DIR/.model_last_used/${model}"
        print_info "Recorded usage for model: ${model}"
    fi
}

# Main wrapper logic
main() {
    # Extract model from the command arguments
    local model=$(extract_model "$@")
    
    # Record usage before making the API call
    if [ -n "$model" ]; then
        record_usage "$model"
    else
        print_warning "Could not determine model from command, skipping usage tracking"
    fi
    
    # Execute the original curl command
    echo ""
    echo "Executing API call..."
    echo "===================="
    curl "$@"
}

# Show usage if no arguments
if [ $# -eq 0 ]; then
    cat << 'EOF'
API Wrapper - Track model usage timestamps
==========================================

This script wraps your curl API calls to track when each model is used.
This enables the auto-offload system to know when to unload idle models.

Usage:
  ./scripts/api-wrapper.sh <curl_command>

Examples:
  # Chat completion
  ./scripts/api-wrapper.sh http://localhost:11434/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d '{"model": "qwen", "messages": [{"role": "user", "content": "Hello"}]}'

  # Completion  
  ./scripts/api-wrapper.sh http://localhost:11434/v1/completions \
    -H "Content-Type: application/json" \
    -d '{"model": "glm", "prompt": "Continue this sentence:"}'

The wrapper will:
1. Extract the model name from your request
2. Record the current timestamp for that model
3. Execute the original curl command
4. Return the API response

This allows the auto-offload daemon to track model usage and
automatically unload models after they have been idle too long.

Note: You need to use this wrapper for ALL API calls to have
accurate usage tracking. Alternatively, modify your application
to call the tracking function directly.
EOF
    exit 0
fi

# Run main function
main "$@"