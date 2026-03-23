#!/bin/bash
# Test script to demonstrate the auto-offload system

set -e

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "==================================="
echo "Auto-Offload System Test"
echo "==================================="
echo ""

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_step() { echo -e "${BLUE}[TEST]${NC} $1"; }
print_success() { echo -e "${GREEN}[✓]${NC} $1"; }
print_info() { echo -e "${YELLOW}[INFO]${NC} $1"; }

# Step 1: Check initial state
print_step "1. Checking initial model status..."
./scripts/check-models.sh
echo ""

# Step 2: Record usage for qwen (simulating API usage)
print_step "2. Recording usage for qwen model..."
./scripts/track-usage.sh qwen
echo ""

# Step 3: Make an API call to trigger qwen loading
print_step "3. Making API call to qwen to trigger loading..."
echo "This will load qwen on-demand..."

# Check if we can make a request
if curl -s http://localhost:11434/v1/chat/completions > /dev/null 2>&1; then
    print_success "API is accessible"

    # Try to make a minimal request to qwen to trigger loading
    echo '{"model": "qwen", "messages": [{"role": "user", "content": "hi"}], "max_tokens": 1}' | \
        curl -s http://localhost:11434/v1/chat/completions \
        -H "Content-Type: application/json" -d @- > /dev/null || true

    # Record that we used qwen
    ./scripts/track-usage.sh qwen
    print_success "qwen API request made (may have triggered loading)"
else
    print_info "API not accessible, skipping load test"
fi
echo ""

# Step 4: Check status after load attempt
print_step "4. Checking model status after load attempt..."
sleep 2
./scripts/check-models.sh
echo ""

# Step 5: Record usage for both models
print_step "5. Recording usage for both models..."
./scripts/track-usage.sh qwen
./scripts/track-usage.sh glm
echo ""

# Step 6: Wait a bit and show idle times
print_step "6. Waiting 5 seconds to show idle time tracking..."
sleep 5
echo ""
print_info "Current idle times:"
for model in qwen glm; do
    if [ -f ".model_last_used/${model}" ]; then
        last_used=$(cat ".model_last_used/${model}")
        idle_seconds=$(($(date +%s) - last_used))
        echo "  ${model}: ${idle_seconds}s idle"
    fi
done
echo ""

# Step 7: Show configuration
print_step "7. Current auto-offload configuration..."
if [ -f "config/models.ini" ]; then
    cat config/models.ini | grep -A3 "\[auto_offload\]" | head -4 || echo "Auto-offload section not found"
else
    print_info "config/models.ini not found"
fi
echo ""

# Step 8: Show summary
print_step "8. Summary..."
echo ""
echo "The auto-offload system is set up with these components:"
echo ""
echo "✓ Scripts created:"
echo "  - scripts/check-models.sh    - Check model status"
echo "  - scripts/load-model.sh      - Trigger model load"
echo "  - scripts/unload-model.sh    - Unload model info"
echo "  - scripts/track-usage.sh    - Record model usage"
echo "  - scripts/api-wrapper.sh    - API calls with tracking"
echo "  - scripts/model-manager.sh  - Auto-offload daemon"
echo ""
echo "✓ Usage tracking directory: .model_last_used/"
echo ""
echo "✓ Configuration file: config/models.ini"
echo ""
echo "✓ Documentation:"
echo "  - AUTO-OFFLOAD-GUIDE.md  - Complete guide"
echo "  - QUICK-REF.md           - Quick reference"
echo ""
print_success "Test complete!"
echo ""
echo "Next steps:"
echo "  1. Configure timeout in config/models.ini"
echo "  2. Start the daemon: ./scripts/model-manager.sh start"
echo "  3. Use API wrapper for tracking: ./scripts/api-wrapper.sh [curl command]"
echo "  4. Monitor logs: tail -f logs/auto-offload.log"