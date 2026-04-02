#!/bin/bash
# Switch between original and RotorQuant versions of llama-server
#
# Usage:
#   ./switch-version.sh original   # Use upstream llama.cpp
#   ./switch-version.sh rotorquant # Use RotorQuant fork (mounts local build)
#   ./switch-version.sh status     # Show current version

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

ROTORQUANT_BUILD="/home/genar/src/rotorquant-test/llama-cpp-turboquant/build"

show_status() {
    echo ""
    
    # Check which compose file is active
    if [ -L docker-compose.yml ] || [ -f docker-compose.active ]; then
        ACTIVE=$(cat docker-compose.active 2>/dev/null || echo "original")
        if [ "$ACTIVE" = "rotorquant" ]; then
            echo -e "Current version: ${GREEN}RotorQuant${NC} (planar3/f16 KV compression)"
        else
            echo -e "Current version: ${YELLOW}Original${NC} (upstream llama.cpp)"
        fi
    else
        echo -e "Current version: ${YELLOW}Original${NC} (upstream llama.cpp)"
    fi
    
    echo ""
    echo "KV Cache config (models.ini):"
    grep -E "^cache-type-" config/models.ini 2>/dev/null | head -4 | sed 's/^/  /'
    echo ""
    
    # Check if container is running
    if docker ps --format '{{.Names}}' | grep -q llama-server; then
        echo -e "Container: ${GREEN}running${NC}"
        docker ps --filter "name=llama-server" --format "  Image: {{.Image}}\n  Status: {{.Status}}"
    else
        echo -e "Container: ${RED}stopped${NC}"
    fi
    echo ""
}

case "${1:-status}" in
    original)
        echo -e "${YELLOW}Switching to ORIGINAL (upstream llama.cpp)...${NC}"
        
        # Stop current container
        docker compose -f docker-compose.rotorquant.yml down 2>/dev/null || true
        docker compose down 2>/dev/null || true
        
        # Restore original configs
        if [ -f config/models.ini.original ]; then
            cp config/models.ini.original config/models.ini
            echo "✅ Restored config/models.ini.original"
        fi
        
        # Mark active version
        echo "original" > docker-compose.active
        
        # Start with original compose
        echo ""
        echo -e "${BLUE}Starting container...${NC}"
        docker compose up -d
        
        show_status
        ;;
        
    rotorquant|rotor)
        echo -e "${GREEN}Switching to ROTORQUANT (planar3/f16 KV compression)...${NC}"
        
        # Check if local build exists
        if [ ! -f "$ROTORQUANT_BUILD/bin/llama-server" ]; then
            echo -e "${RED}ERROR: RotorQuant build not found at $ROTORQUANT_BUILD${NC}"
            echo "Build it first:"
            echo "  cd ~/src/rotorquant-test"
            echo "  ./test-rotorquant.sh"
            exit 1
        fi
        echo "✅ RotorQuant build found"
        
        # Stop current container
        docker compose down 2>/dev/null || true
        docker compose -f docker-compose.rotorquant.yml down 2>/dev/null || true
        
        # Update models.ini to use planar3/f16 (if not already)
        if ! grep -q "cache-type-k = planar3" config/models.ini; then
            sed -i 's/cache-type-k = q8_0/cache-type-k = planar3/g' config/models.ini
            sed -i 's/cache-type-k = q4_0/cache-type-k = planar3/g' config/models.ini
            sed -i 's/cache-type-v = q8_0/cache-type-v = f16/g' config/models.ini
            sed -i 's/cache-type-v = q4_0/cache-type-v = f16/g' config/models.ini
            echo "✅ Updated models.ini for planar3/f16"
        else
            echo "✅ models.ini already configured for planar3/f16"
        fi
        
        # Mark active version
        echo "rotorquant" > docker-compose.active
        
        # Build the lightweight runtime image (no llama.cpp compilation)
        echo ""
        echo -e "${BLUE}Building runtime image...${NC}"
        docker compose -f docker-compose.rotorquant.yml build
        
        # Start with rotorquant compose
        echo ""
        echo -e "${BLUE}Starting container...${NC}"
        docker compose -f docker-compose.rotorquant.yml up -d
        
        show_status
        ;;
        
    status)
        show_status
        ;;
        
    *)
        echo "Usage: $0 {original|rotorquant|status}"
        echo ""
        echo "  original   - Use upstream llama.cpp (ghcr.io/ggml-org image)"
        echo "  rotorquant - Use RotorQuant fork with KV compression (local build)"
        echo "  status     - Show current configuration"
        echo ""
        echo "RotorQuant benefits:"
        echo "  - planar3/f16: +5% decode, +10% prefill, 5.1x K-compression, zero PPL loss"
        echo "  - planar3/planar3: 10.3x compression, ~4-6% PPL hit"
        exit 1
        ;;
esac
