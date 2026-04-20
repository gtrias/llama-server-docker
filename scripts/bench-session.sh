#!/bin/bash
# bench-session.sh — Simulate a PI agent session with growing context
# Usage: ./scripts/bench-session.sh [max_calls]
# Requires: curl, jq, nvidia-smi, llama-server running on localhost:11434

set -uo pipefail

ENDPOINT="http://localhost:11434/v1/chat/completions"
MODEL="qwen36-apex"
MAX_CALLS=${1:-50}
GEN_TOKENS=150
TIMEOUT=180
PAUSE_SECS=1

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "=== Session Benchmark ($(date)) ==="
echo "Model: $MODEL | Max calls: $MAX_CALLS"
echo ""

# Verify server
if ! curl -sf "http://localhost:11434/health" -o /dev/null --max-time 5 2>/dev/null; then
    echo -e "${RED}ERROR: llama-server not responding${NC}"
    exit 1
fi

# Tasks that simulate real PI agent work (varied, code-heavy)
TASKS=(
    "Write a TypeScript function that validates an email address using regex. Include tests."
    "Explain the difference between O(n log n) and O(n²) sorting. Give examples."
    "Write a bash function that finds all .ts files modified in the last 24 hours."
    "Create a Python dataclass for a User with name, email, created_at, and is_active fields."
    "Write a SQL query to find the top 10 customers by total orders in the last 30 days."
    "Explain React hooks: useState, useEffect, useMemo. Give a short example of each."
    "Write a git command to squash the last 5 commits into one with a new message."
    "Create a Dockerfile for a Node.js 22 app with health check and non-root user."
    "Write a regex to match URLs with optional port, path, and query string."
    "Explain the CAP theorem. Which combinations are possible? Give real-world examples."
    "Write a jq filter to extract names and emails from a JSON array of users."
    "Create a Convex schema for a blog with posts, comments, and authors."
    "Write a curl command to POST JSON with authentication headers to an API."
    "Explain the difference between TCP and UDP. When would you use each?"
    "Write a Python function that chunkifies a list into sublists of size N."
    "Create a Kubernetes deployment YAML for a web app with 3 replicas and a liveness probe."
    "Write a TypeScript generic function that deeply merges two objects."
    "Explain database indexing. When should you add a composite index? Give examples."
    "Write a script that monitors a log file and alerts on ERROR lines."
    "Create a Traefik labels configuration for a Docker container with HTTPS and basic auth."
)

# Conversation history
MESSAGES='[{"role":"system","content":"You are a coding assistant. Be concise and practical."}]'
CALL_NUM=0
FAILED=false
PREV_TOTAL=0

printf "%-5s %-10s %-10s %-10s %-11s %-10s %s\n" "Call" "Ctx(tok)" "Gen(tok)" "Tok/s" "Time(ms)" "VRAM(MB)" "Status"
echo "----- ---------- ---------- ---------- ----------- ---------- ----------"

while [ "$CALL_NUM" -lt "$MAX_CALLS" ] && [ "$FAILED" = "false" ]; do
    CALL_NUM=$(( CALL_NUM + 1 ))

    # Pick a task (cycle through)
    TASK_IDX=$(( (CALL_NUM - 1) % ${#TASKS[@]} ))
    USER_MSG="${TASKS[$TASK_IDX]}"

    # Append user message
    MESSAGES=$(echo "$MESSAGES" | jq --arg msg "$USER_MSG" '. + [{"role":"user","content":$msg}]')

    VRAM=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | tr -d ' ')
    START_MS=$(date +%s%3N)

    RESPONSE=$(curl -sf "$ENDPOINT" \
        -H "Content-Type: application/json" \
        --max-time "$TIMEOUT" \
        -d "{
            \"model\": \"$MODEL\",
            \"messages\": $MESSAGES,
            \"max_tokens\": $GEN_TOKENS,
            \"temperature\": 0.3,
            \"stream\": false
        }" 2>&1) || {
        END_MS=$(date +%s%3N)
        ELAPSED_MS=$(( END_MS - START_MS ))
        FAILED=true
        ERR=$(echo "$RESPONSE" | head -1 | cut -c1-50)
        printf "${RED}%-5s %-10s %-10s %-10s %-11s %-10s %s${NC}\n" "$CALL_NUM" "?" "?" "?" "$ELAPSED_MS" "$VRAM" "FAIL: curl error"
        break
    }

    END_MS=$(date +%s%3N)
    ELAPSED_MS=$(( END_MS - START_MS ))

    if echo "$RESPONSE" | jq -e '.choices[0].message.content' >/dev/null 2>&1; then
        PROMPT_T=$(echo "$RESPONSE" | jq -r '.usage.prompt_tokens // 0')
        COMP_T=$(echo "$RESPONSE" | jq -r '.usage.completion_tokens // 0')
        TOTAL_T=$(( PROMPT_T + COMP_T ))

        if [ "$COMP_T" -gt 0 ] && [ "$ELAPSED_MS" -gt 0 ]; then
            TOK_S=$(echo "scale=1; $COMP_T * 1000 / $ELAPSED_MS" | bc 2>/dev/null || echo "?")
        else
            TOK_S="?"
        fi

        # Detect compaction (context shrinks dramatically)
        STATUS="OK"
        if [ "$PREV_TOTAL" -gt 10000 ] && [ "$TOTAL_T" -lt "$(( PREV_TOTAL / 2 ))" ]; then
            STATUS="${YELLOW}COMPACTION${NC}"
        fi
        PREV_TOTAL=$TOTAL_T

        printf "%-5s %-10s %-10s %-10s %-11s %-10s %b\n" "$CALL_NUM" "$TOTAL_T" "$COMP_T" "$TOK_S" "$ELAPSED_MS" "$VRAM" "$STATUS"

        # Append assistant response
        ASSISTANT_MSG=$(echo "$RESPONSE" | jq -r '.choices[0].message.content')
        MESSAGES=$(echo "$MESSAGES" | jq --arg msg "$ASSISTANT_MSG" '. + [{"role":"assistant","content":$msg}]')
    else
        FAILED=true
        ERR=$(echo "$RESPONSE" | jq -r '.error.message // "Unknown"' 2>/dev/null || echo "$RESPONSE" | head -1 | cut -c1-50)
        printf "${RED}%-5s %-10s %-10s %-10s %-11s %-10s %s${NC}\n" "$CALL_NUM" "?" "?" "?" "$ELAPSED_MS" "$VRAM" "FAIL: $ERR"
        break
    fi

    sleep "$PAUSE_SECS"
done

echo ""
echo "=== Session Summary ==="
echo "Completed: $CALL_NUM / $MAX_CALLS calls"
if [ "$FAILED" = "false" ]; then
    echo -e "Result: ${GREEN}All calls completed${NC}"
else
    echo -e "Result: ${RED}Failed at call $CALL_NUM${NC}"
fi

echo ""
echo "=== Last 20 llama-server logs ==="
docker logs llama-server --tail 20 2>&1 || echo "(could not fetch docker logs)"
