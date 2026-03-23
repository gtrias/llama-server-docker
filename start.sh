#!/bin/bash

# Llama Server Docker - Startup Script (Router Mode)
# Usage: ./start.sh
#
# Router mode auto-discovers models and loads them on-demand.

set -e

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_step() { echo -e "${BLUE}[STEP]${NC} $1"; }

print_info "Llama Server Docker - Router Mode"
print_info "=================================="

# Step 1: Check .env
print_step "Checking configuration..."
if [ ! -f .env ]; then
    if [ -f .env.example ]; then
        print_warning ".env not found, copying from .env.example..."
        cp .env.example .env
    else
        print_error "Neither .env nor .env.example found!"
        exit 1
    fi
fi

# Step 2: Check models.ini
print_step "Checking models preset..."
if [ ! -f config/models.ini ]; then
    print_warning "config/models.ini not found, creating default..."
    mkdir -p config
    cat > config/models.ini << 'EOF'
# llama-server model presets
# Models are loaded on-demand from the cache

[Qwen/Qwen3-Coder-Next-GGUF:Q4_K_M]
alias = qwen
hf-repo = Qwen/Qwen3-Coder-Next-GGUF:Q4_K_M
ctx-size = 160000
n-gpu-layers = -1
flash-attn = on
temp = 0.3
top-p = 0.9
repeat-penalty = 1.1
parallel = 2

[unsloth/GLM-4.7-Flash-REAP-23B-A3B-GGUF:IQ4_NL]
alias = glm
hf-repo = unsloth/GLM-4.7-Flash-REAP-23B-A3B-GGUF:IQ4_NL
ctx-size = 16384
n-gpu-layers = -1
flash-attn = on
temp = 0.5
top-p = 0.95
repeat-penalty = 1.05
EOF
fi

# Step 3: Build image if needed
print_step "Checking Docker image..."
if ! docker images | grep -q llama-server; then
    print_warning "Image not found, building..."
    docker-compose build
else
    print_info "Docker image exists"
fi

# Step 4: Start container
print_step "Starting llama-server container..."
if docker ps | grep -q llama-server; then
    print_warning "Container already running, recreating..."
    docker-compose down
fi

docker-compose up -d

# Step 5: Wait for health check
print_step "Waiting for server to be healthy..."
MAX_WAIT=60
WAITED=0
while [ $WAITED -lt $MAX_WAIT ]; do
    if curl -s http://localhost:11434/health > /dev/null 2>&1; then
        print_info "✓ Server is healthy!"
        break
    fi
    sleep 2
    WAITED=$((WAITED + 2))
    echo -n "."
done
echo

# Step 6: List available models
print_step "Listing available models..."
sleep 2
curl -s http://localhost:11434/models 2>/dev/null | jq -r '.data[] | "\(.id) - \(.status.value)"' 2>/dev/null || print_warning "Could not list models (may need to download first)"

# Step 7: Show status
if [ $WAITED -lt $MAX_WAIT ]; then
    print_info "=================================="
    print_info "Server ready!"
    echo ""
    print_info "Endpoints:"
    echo "  API:       http://localhost:11434/v1"
    echo "  Health:    http://localhost:11434/health"
    echo "  Models:    http://localhost:11434/models"
    echo "  Web UI:    http://localhost:11434 (built-in web UI at /)"
    echo ""
    print_info "Router Mode Features:"
    echo "  • Models auto-discovered from cache"
    echo "  • Lazy loading on first request"
    echo "  • LRU eviction when max (4) reached"
    echo ""
    print_info "Commands:"
    echo "  curl http://localhost:11434/models | jq           # List models"
    echo "  curl http://localhost:11434/health                 # Health check"
    echo "  docker-compose logs -f                            # View logs"
    echo "  docker-compose down                               # Stop server"
    echo ""
    print_info "Chat example:"
    echo "  curl http://localhost:11434/v1/chat/completions \\"
    echo "    -H 'Content-Type: application/json' \\"
    echo "    -d '{\"model\": \"qwen\", \"messages\": [{\"role\": \"user\", \"content\": \"Hello!\"}]}'"
    echo ""
    print_info "Model Management (via Web UI at http://localhost:11434/):"
    echo "  • View all available models"
    echo "  • Load/unload models manually"
    echo "  • Monitor GPU memory usage"
else
    print_error "Server did not become healthy in time"
    print_error "Check logs: docker-compose logs llama-server"
    exit 1
fi
