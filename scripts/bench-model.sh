#!/bin/bash
# bench-model.sh — Benchmark Qwen 3.6 tok/s at different context sizes
# Usage: ./scripts/bench-model.sh
# Requires: curl, jq, nvidia-smi, llama-server running on localhost:11434

set -euo pipefail

ENDPOINT="http://localhost:11434/v1/chat/completions"
MODEL="qwen36-apex"
CONTEXT_SIZES=(4096 16384 32768 65536)
GEN_TOKENS=200
TIMEOUT=180

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "=== Model Benchmark ($(date)) ==="
echo "Endpoint: $ENDPOINT"
echo "Model: $MODEL"
echo ""

# Verify server is up
if ! curl -sf "http://localhost:11434/health" -o /dev/null --max-time 5 2>/dev/null; then
    echo -e "${RED}ERROR: llama-server not responding at localhost:11434${NC}"
    exit 1
fi
echo -e "${GREEN}Server is up${NC}"
echo ""

printf "| %-10s | %-12s | %-12s | %-12s | %-10s |\n" "Context" "Tok/s gen" "Time (ms)" "VRAM (MB)" "Status"
printf "| %-10s | %-12s | %-12s | %-12s | %-10s |\n" "----------" "------------" "------------" "------------" "----------"

for CTX in "${CONTEXT_SIZES[@]}"; do
    # Build padding to fill ~80% of context
    # Each "paragraph" is ~200 chars ≈ ~50 tokens
    PAD_COUNT=$(( CTX * 8 / 10 / 50 ))  # 80% fill, ~50 tokens per unit
    PAD_COUNT=$(( PAD_COUNT > 0 ? PAD_COUNT : 1 ))

    # Generate JSON-safe padding
    SYSTEM_MSG=$(printf 'Word%05d. ' $(seq 1 "$PAD_COUNT") | cut -c1-$(( CTX * 3 / 10 )))

    # Escape for JSON
    SYSTEM_JSON=$(echo "$SYSTEM_MSG" | jq -Rs .)

    START_MS=$(date +%s%3N)

    RESPONSE=$(curl -sf "$ENDPOINT" \
        -H "Content-Type: application/json" \
        --max-time "$TIMEOUT" \
        -d "{
            \"model\": \"$MODEL\",
            \"messages\": [
                {\"role\": \"system\", \"content\": $SYSTEM_JSON},
                {\"role\": \"user\", \"content\": \"Reply with exactly: Benchmark complete. Then list numbers 1 to 30.\"}
            ],
            \"max_tokens\": $GEN_TOKENS,
            \"temperature\": 0.1,
            \"stream\": false
        }" 2>&1) || true

    END_MS=$(date +%s%3N)
    ELAPSED_MS=$(( END_MS - START_MS ))

    VRAM=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | tr -d ' ')

    if echo "$RESPONSE" | jq -e '.choices[0].message.content' >/dev/null 2>&1; then
        PROMPT_T=$(echo "$RESPONSE" | jq -r '.usage.prompt_tokens // 0')
        COMP_T=$(echo "$RESPONSE" | jq -r '.usage.completion_tokens // 0')

        if [ "$COMP_T" -gt 0 ] && [ "$ELAPSED_MS" -gt 0 ]; then
            TOK_S=$(echo "scale=1; $COMP_T * 1000 / $ELAPSED_MS" | bc 2>/dev/null || echo "?")
        else
            TOK_S="?"
        fi

        printf "| %-10s | %-12s | %-12s | %-12s | ${GREEN}%-10s${NC} |\n" "${PROMPT_T}" "$TOK_S" "$ELAPSED_MS" "$VRAM" "OK"
    else
        ERROR=$(echo "$RESPONSE" | jq -r '.error.message // "curl error"' 2>/dev/null || echo "curl/timeout")
        ERROR_SHORT=$(echo "$ERROR" | cut -c1-40)
        printf "| %-10s | %-12s | %-12s | %-12s | ${RED}%-10s${NC} |\n" "~${CTX}" "-" "$ELAPSED_MS" "$VRAM" "FAIL: ${ERROR_SHORT}"
    fi

    sleep 3
done

echo ""
echo "=== Done ==="
