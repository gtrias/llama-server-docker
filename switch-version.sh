#!/bin/bash
# Switch between standard and RotorQuant llama-server images.
#
# Usage:
#   ./switch-version.sh standard    # Use upstream llama.cpp
#   ./switch-version.sh rotorquant  # Use RotorQuant fork
#   ./switch-version.sh status      # Show current version
#   ./switch-version.sh build       # (Re)build the rotorquant image

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

ROTORQUANT_BUILD="/home/genar/src/rotorquant-test/llama-cpp-turboquant/build/bin"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

current_tag() {
    grep "^IMAGE_TAG=" .env 2>/dev/null | cut -d= -f2 || echo "standard"
}

set_tag() {
    local tag="$1"
    if grep -q "^IMAGE_TAG=" .env 2>/dev/null; then
        sed -i "s/^IMAGE_TAG=.*/IMAGE_TAG=$tag/" .env
    else
        echo "IMAGE_TAG=$tag" >> .env
    fi
}

show_status() {
    local tag
    tag=$(current_tag)
    echo ""
    echo -e "Current version: ${GREEN}${tag}${NC}"
    if docker ps --format '{{.Names}}' | grep -q "^llama-server$"; then
        echo -e "Container: ${GREEN}running${NC}"
        docker ps --filter "name=llama-server" --format "  Image: {{.Image}}  Status: {{.Status}}"
    else
        echo -e "Container: ${RED}stopped${NC}"
    fi
    echo ""
}

build_rotorquant() {
    echo -e "${BLUE}Staging RotorQuant binaries from $ROTORQUANT_BUILD...${NC}"
    if [ ! -f "$ROTORQUANT_BUILD/llama-server" ]; then
        echo -e "${RED}ERROR: binary not found at $ROTORQUANT_BUILD/llama-server${NC}"
        echo "Build it first in ~/src/rotorquant-test/llama-cpp-turboquant"
        exit 1
    fi

    rm -rf rotorquant-bin
    mkdir -p rotorquant-bin
    cp "$ROTORQUANT_BUILD/llama-server" rotorquant-bin/
    cp "$ROTORQUANT_BUILD/llama-cli" rotorquant-bin/ 2>/dev/null || true
    cp "$ROTORQUANT_BUILD"/*.so* rotorquant-bin/ 2>/dev/null || true
    echo -e "${GREEN}✅ Binaries staged ($(ls rotorquant-bin | wc -l) files)${NC}"

    echo -e "${BLUE}Building llama-server:rotorquant image...${NC}"
    docker build -f Dockerfile.rotorquant -t llama-server:rotorquant .
    echo -e "${GREEN}✅ Image built: llama-server:rotorquant${NC}"
}

case "${1:-status}" in
    standard)
        echo -e "${YELLOW}Switching to standard...${NC}"
        set_tag "standard"
        docker compose up -d
        show_status
        ;;

    rotorquant|rotor)
        echo -e "${YELLOW}Switching to rotorquant...${NC}"
        if ! docker image inspect llama-server:rotorquant &>/dev/null; then
            echo "Image llama-server:rotorquant not found — building first..."
            build_rotorquant
        fi
        set_tag "rotorquant"
        docker compose up -d
        show_status
        ;;

    build)
        build_rotorquant
        ;;

    status)
        show_status
        ;;

    *)
        echo "Usage: $0 {standard|rotorquant|build|status}"
        echo ""
        echo "  standard    - Run upstream llama.cpp image (llama-server:standard)"
        echo "  rotorquant  - Run RotorQuant image (builds if not yet built)"
        echo "  build       - (Re)build the rotorquant image from local binary"
        echo "  status      - Show current version and container state"
        exit 1
        ;;
esac
