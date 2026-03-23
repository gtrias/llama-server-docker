#!/bin/bash
# Healthcheck for llama-server router mode.
#
# Problem: when a child model server crashes (e.g. CUDA OOM), the router
# keeps proxying to a dead port, returning 500 forever. The router itself
# stays healthy. The only recovery is restarting the container.
#
# Strategy:
# 1. Check the router is alive (/health)
# 2. Query /v1/models for models with status != "unloaded"
# 3. For any "loaded" model, verify the child process is still running
#    by checking that a child llama-server process exists under PID 1
#
# If a model claims to be loaded but no child process backs it,
# exit 1 so Docker's restart policy recycles the container.

set -euo pipefail

ROUTER="http://localhost:8080"

# Step 1: Router must be alive
if ! curl -sf --max-time 5 "${ROUTER}/health" > /dev/null; then
    echo "healthcheck: router unreachable"
    exit 1
fi

# Step 2: Check if any model is loaded (status != "unloaded")
LOADED_COUNT=$(curl -sf --max-time 5 "${ROUTER}/v1/models" \
    | jq '[.data[] | select(.status.value != "unloaded")] | length' 2>/dev/null || echo "0")

if [ "$LOADED_COUNT" = "0" ]; then
    # No models loaded — router is idle, nothing to verify
    exit 0
fi

# Step 3: A model claims to be loaded — verify child process exists
# The router (PID 1) spawns child llama-server processes for each loaded model.
# Count child processes of PID 1 that are llama-server instances.
CHILD_COUNT=$(pgrep -c -P 1 -f "llama-server" 2>/dev/null || echo "0")

if [ "$CHILD_COUNT" -eq 0 ]; then
    echo "healthcheck: ${LOADED_COUNT} model(s) reported as loaded but no child processes found — child likely crashed"
    exit 1
fi

exit 0
