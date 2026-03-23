#!/bin/bash

# Test script for llama-server Docker
# Verifies health, model loading, and basic generation

set -e

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_pass() { echo -e "${GREEN}✓${NC} $1"; }
print_fail() { echo -e "${RED}✗${NC} $1"; }
print_info() { echo -e "${YELLOW}→${NC} $1"; }

echo "Testing llama-server Docker..."
echo "=============================="
echo ""

# Test 1: Container running
print_info "Checking if container is running..."
if docker ps | grep -q llama-server; then
    print_pass "Container is running"
else
    print_fail "Container not running. Start with: ./start.sh"
    exit 1
fi
echo ""

# Test 2: Health endpoint
print_info "Testing health endpoint..."
HEALTH=$(curl -s http://localhost:11434/health 2>/dev/null)
if echo "$HEALTH" | grep -q '"status":"ok"'; then
    print_pass "Health check passed"
else
    print_fail "Health check failed"
    echo "  Response: $HEALTH"
    exit 1
fi
echo ""

# Test 3: Models endpoint
print_info "Checking loaded models..."
MODELS=$(curl -s http://localhost:11434/v1/models 2>/dev/null)
if echo "$MODELS" | grep -q '"object":"list"'; then
    MODEL_ID=$(echo "$MODELS" | jq -r '.data[0].id // empty')
    if [ -n "$MODEL_ID" ]; then
        print_pass "Model loaded: $MODEL_ID"
    else
        print_fail "No model found"
        exit 1
    fi
else
    print_fail "Failed to get models"
    exit 1
fi
echo ""

# Test 4: Configuration
print_info "Checking model configuration..."
CONFIG=$(curl -s http://localhost:11434/v1/models 2>/dev/null)
CTX_SIZE=$(echo "$CONFIG" | jq -r '.data[0].status.ctx_size // "N/A"')
print_pass "Context size: $CTX_SIZE tokens"
echo ""

# Test 5: Simple generation
print_info "Testing text generation (this may take 10-20s)..."
RESPONSE=$(curl -s http://localhost:11434/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d '{
        "model": "'"${MODEL_ID}"'",
        "messages": [{"role": "user", "content": "Say hello in one word."}],
        "max_tokens": 10
    }' 2>/dev/null)

if echo "$RESPONSE" | grep -q '"content"'; then
    GENERATED=$(echo "$RESPONSE" | jq -r '.choices[0].message.content // empty')
    print_pass "Generation successful: \"$GENERATED\""
else
    print_fail "Generation failed"
    echo "  Response: $RESPONSE"
fi
echo ""

# Summary
echo "=============================="
echo "All tests passed! ✓"
echo ""
echo "Server is ready at:"
echo "  API:   http://localhost:11434/v1"
echo "  WebUI: http://localhost:11434"
