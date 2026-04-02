# Simplify llama-server-docker Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Consolidate to one docker-compose.yml, two pre-built images (standard/rotorquant), one models.ini, and a simple switch-version.sh.

**Architecture:** Single `docker-compose.yml` uses `IMAGE_TAG` env var to select which pre-built image to run. `Dockerfile.rotorquant` is rewritten to COPY the local binary at build time instead of mounting it via volume. `switch-version.sh` updates `.env` and runs `docker compose up -d`.

**Tech Stack:** Docker, docker compose, bash, Traefik

---

### Task 1: Clean up obsolete files

**Files:**
- Delete: `docker-compose.rotorquant.yml`
- Delete: `Dockerfile.rotorquant-local`
- Delete: `config/models.conf`

**Step 1: Delete the files**

```bash
cd /home/genar/src/llama-server-docker
rm docker-compose.rotorquant.yml
rm Dockerfile.rotorquant-local
rm config/models.conf
```

**Step 2: Verify they're gone**

```bash
ls docker-compose*.yml Dockerfile.rotorquant* config/models.*
```

Expected output:
```
docker-compose.yml
Dockerfile.rotorquant
config/models.ini
config/models.ini.original
```

**Step 3: Commit**

```bash
git add -A
git commit -m "chore: remove obsolete docker-compose, dockerfile, and models.conf"
```

---

### Task 2: Rewrite Dockerfile.rotorquant to COPY binary at build time

**Files:**
- Modify: `Dockerfile.rotorquant`

The new Dockerfile should be a lightweight runtime image (no compilation). It COPYs the pre-built binary from the local path using a build context that includes the binary.

**Step 1: Rewrite Dockerfile.rotorquant**

```dockerfile
# Dockerfile.rotorquant
# Runtime image using pre-built RotorQuant binary.
# Build: docker compose build rotorquant
# Prerequisites: binary must exist at ../rotorquant-test/llama-cpp-turboquant/build/bin/

FROM nvidia/cuda:12.8.1-runtime-ubuntu24.04

RUN apt-get update && apt-get install -y \
    curl \
    wget \
    jq \
    python3 \
    python3-pip \
    python3-venv \
    libgomp1 \
    && pip3 install --break-system-packages huggingface-hub \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /models /cache /app /usr/local/lib/llama

WORKDIR /app

# Copy pre-built RotorQuant binaries and libraries
# These are built from: ~/src/rotorquant-test/llama-cpp-turboquant
COPY rotorquant-bin/llama-server /app/llama-server
COPY rotorquant-bin/llama-cli /usr/local/bin/llama-cli
COPY rotorquant-bin/ /usr/local/lib/llama/

RUN chmod +x /app/llama-server /usr/local/bin/llama-cli
RUN echo "/usr/local/lib/llama" > /etc/ld.so.conf.d/llama.conf && ldconfig

COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh
COPY config/ /app/config/
COPY scripts/ /app/scripts/

ENV LLAMA_ARG_HOST=0.0.0.0
ENV LLAMA_ARG_PORT=8080
ENV LLAMA_ARG_JINJA=true

EXPOSE 8080

ENTRYPOINT ["/app/entrypoint.sh"]
```

**Step 2: Create a helper script to stage the binary before building**

The docker build context can't reach outside its directory, so we stage the binary into a `rotorquant-bin/` folder (gitignored) before building.

Add to `.gitignore`:
```
rotorquant-bin/
```

**Step 3: Commit**

```bash
git add Dockerfile.rotorquant .gitignore
git commit -m "feat: rewrite Dockerfile.rotorquant to COPY binary at build time"
```

---

### Task 3: Update docker-compose.yml to support IMAGE_TAG

**Files:**
- Modify: `docker-compose.yml`
- Modify: `.env`

**Step 1: Update docker-compose.yml**

Replace the `build:` section and `image:` line in the `llama-server` service so it uses the `IMAGE_TAG` variable:

```yaml
  llama-server:
    image: llama-server:${IMAGE_TAG:-standard}
    container_name: llama-server
```

Remove the `build:` key entirely — images are built explicitly, not via `docker compose up`.

Also fix the Traefik labels (they must match what's in the standard compose):
```yaml
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.llama-server.rule=Host(`${TRAEFIK_HOST:-llama.localhost}`)"
      - "traefik.http.routers.llama-server.tls=true"
      - "traefik.http.routers.llama-server.tls.certresolver=default"
      - "traefik.http.routers.llama-server.middlewares=llama-auth"
      - "traefik.http.services.llama-server.loadbalancer.server.port=8080"
      - "traefik.http.middlewares.llama-auth.basicauth.users=${TRAEFIK_BASICAUTH:-}"
```

**Step 2: Add IMAGE_TAG to .env**

```bash
echo "IMAGE_TAG=standard" >> .env
```

**Step 3: Verify the compose file is valid**

```bash
docker compose config | grep "image:"
```

Expected: `image: llama-server:standard`

**Step 4: Commit**

```bash
git add docker-compose.yml .env
git commit -m "feat: use IMAGE_TAG in docker-compose.yml for version switching"
```

---

### Task 4: Rewrite switch-version.sh

**Files:**
- Modify: `switch-version.sh`

**Step 1: Rewrite switch-version.sh**

```bash
#!/bin/bash
# Switch between standard and RotorQuant llama-server images.
#
# Usage:
#   ./switch-version.sh standard    # Use upstream llama.cpp
#   ./switch-version.sh rotorquant  # Use RotorQuant fork
#   ./switch-version.sh status      # Show current version
#   ./switch-version.sh build       # Build/rebuild the rotorquant image

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
    if docker ps --format '{{.Names}}' | grep -q llama-server; then
        echo -e "Container: ${GREEN}running${NC}"
        docker ps --filter "name=llama-server" --format "  Image: {{.Image}}  Status: {{.Status}}"
    else
        echo -e "Container: ${RED}stopped${NC}"
    fi
    echo ""
}

build_rotorquant() {
    echo -e "${BLUE}Staging RotorQuant binaries...${NC}"
    if [ ! -f "$ROTORQUANT_BUILD/llama-server" ]; then
        echo -e "${RED}ERROR: binary not found at $ROTORQUANT_BUILD/llama-server${NC}"
        echo "Build it first in ~/src/rotorquant-test/llama-cpp-turboquant"
        exit 1
    fi
    rm -rf rotorquant-bin
    mkdir -p rotorquant-bin
    cp "$ROTORQUANT_BUILD"/llama-server rotorquant-bin/
    cp "$ROTORQUANT_BUILD"/llama-cli rotorquant-bin/ 2>/dev/null || true
    cp "$ROTORQUANT_BUILD"/*.so* rotorquant-bin/ 2>/dev/null || true
    echo -e "${GREEN}✅ Binaries staged${NC}"

    echo -e "${BLUE}Building llama-server:rotorquant image...${NC}"
    docker build -f Dockerfile.rotorquant -t llama-server:rotorquant .
    echo -e "${GREEN}✅ Image built${NC}"
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
        # Check image exists
        if ! docker image inspect llama-server:rotorquant &>/dev/null; then
            echo "Image llama-server:rotorquant not found. Building..."
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
        echo "  standard    - Run upstream llama.cpp image"
        echo "  rotorquant  - Run RotorQuant image (builds if needed)"
        echo "  build       - (Re)build the rotorquant image from local binary"
        echo "  status      - Show current version and container state"
        exit 1
        ;;
esac
```

**Step 2: Make it executable**

```bash
chmod +x switch-version.sh
```

**Step 3: Commit**

```bash
git add switch-version.sh
git commit -m "feat: simplify switch-version.sh to use IMAGE_TAG and single compose file"
```

---

### Task 5: Build the standard image and verify

**Step 1: Build standard image**

```bash
docker build -t llama-server:standard .
```

**Step 2: Switch to standard and verify it starts**

```bash
./switch-version.sh standard
sleep 10
docker logs llama-server --tail 20
```

Expected: server listening on `http://0.0.0.0:8080`, models loaded from preset.

**Step 3: Verify Traefik picks it up**

```bash
curl -s http://localhost:8088/api/http/routers | python3 -c "import sys,json; [print(r['name'], r['status']) for r in json.load(sys.stdin) if 'llama' in r['name'].lower()]"
```

Expected: `llama-server@docker enabled`

**Step 4: Verify https://llama.casa.genar.me is accessible**

```bash
curl -sk -o /dev/null -w "%{http_code}" https://llama.casa.genar.me/health
```

Expected: `401` (basic auth prompt = Traefik routing works)

---

### Task 6: Build the rotorquant image and verify switching

**Step 1: Build rotorquant image**

```bash
./switch-version.sh build
```

Expected: `✅ Image built`

**Step 2: Switch to rotorquant**

```bash
./switch-version.sh rotorquant
sleep 10
docker logs llama-server --tail 20
```

Expected: server starts with RotorQuant binary, models available.

**Step 3: Switch back to standard**

```bash
./switch-version.sh standard
```

**Step 4: Commit any final tweaks**

```bash
git add -A
git commit -m "chore: verify both images work, setup complete"
```

---

### Task 7: Add Gemma 4 models to models.ini

**Files:**
- Modify: `config/models.ini`

**Step 1: Add Gemma 4 entries**

Add to `config/models.ini` following the existing format. Example (adjust hf-repo/hf-file to actual Gemma 4 GGUF):

```ini
[gemma4-12b]
alias = gemma4-12b
model = /root/.cache/llama.cpp/gemma-4-12b-it-Q4_K_M.gguf
hf-repo = google/gemma-4-12b-it-GGUF
hf-file = gemma-4-12b-it-Q4_K_M.gguf
ctx-size = 131072
n-gpu-layers = -1
flash-attn = on
cache-type-k = q8_0
cache-type-v = q8_0
temp = 1.0
top-p = 0.95
top-k = 40
repeat-penalty = 1.0
parallel = 1
kv-unified = 1
```

**Step 2: Verify the config parses (test with a dry run)**

```bash
docker exec llama-server cat /tmp/models-clean.ini | grep -A3 "gemma4"
```

**Step 3: Commit**

```bash
git add config/models.ini
git commit -m "feat: add Gemma 4 models to models.ini"
```
