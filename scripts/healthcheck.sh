# Healthcheck for llama-server router mode.
#
# Detects three failure modes:
# 1. Router dead                → exit 1 (dead container, Docker restarts)
# 2. Child process crashed      → exit 1 (model loaded but no backing process)
# 3. Zombie child (cancel loop) → exit 1 (child alive but stuck retrying
#    after checkpoint corruption / non-consecutive token positions)
#
# Mode 3 is the novel case: the child process is alive and responding,
# but every request hits a corrupted slot, gets canceled within ~1s,
# and the LCP cache-reselect loop makes it pick the same slot forever.
# Signature: rapid "stop: cancel task" events in the log.

set -euo pipefail

ROUTER="http://localhost:8080"

# Step 1: Router must be alive
if ! curl -sf --max-time 5 "${ROUTER}/health" > /dev/null; then
    echo "healthcheck: router unreachable"
    exit 1
fi

# Step 2: Zombie-loop detection — runs regardless of model load state.
# Signature: "stop: cancel task" accumulating rapidly in the log.
# Normal operation: 0 cancels. Zombie: ~1 cancel per second.
# Window: last 500 log lines (~30s of zombie output, ~minutes of healthy).
LOG_FILE="/app/logs/llama-server.log"
if [ -f "$LOG_FILE" ]; then
    CANCEL_COUNT=$(tail -n 500 "$LOG_FILE" 2>/dev/null | grep -c 'stop: cancel task' || echo "0")
    if [ "$CANCEL_COUNT" -gt 10 ]; then
        echo "healthcheck: zombie-loop detected — ${CANCEL_COUNT} task cancellations in recent log window"
        echo "healthcheck: sending SIGTERM to llama-server (PID 1) to trigger container restart"
        kill -TERM 1
        sleep 2
        exit 1
    fi
fi

# Step 3: Check if any model is loaded (status != "unloaded")
LOADED_COUNT=$(curl -sf --max-time 5 "${ROUTER}/v1/models" \
    | jq '[.data[] | select(.status.value != "unloaded")] | length' 2>/dev/null || echo "0")

if [ "$LOADED_COUNT" = "0" ]; then
    # No models loaded — router is idle, nothing to verify beyond zombie check
    exit 0
fi

# Step 4: A model claims to be loaded — verify child process exists
# The router (PID 1) spawns child llama-server processes for each loaded model.
CHILD_COUNT=$(pgrep -c -P 1 -f "llama-server" 2>/dev/null || echo "0")

if [ "$CHILD_COUNT" -eq 0 ]; then
    echo "healthcheck: ${LOADED_COUNT} model(s) reported as loaded but no child processes found — child likely crashed"
    exit 1
fi

exit 0
