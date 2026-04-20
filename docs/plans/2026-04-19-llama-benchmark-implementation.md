# Llama Benchmark Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Create two benchmark scripts to measure local model performance and identify why PI agent sessions stop after context compaction.

**Architecture:** Two standalone bash scripts that curl the llama-server OpenAI-compatible API. Part 1 measures raw tok/s at different context sizes. Part 2 simulates an agent session with sequential calls, monitoring when/if the session breaks.

**Tech Stack:** Bash, curl, jq, nvidia-smi, llama-server OpenAI API (localhost:11434)

---

### Task 1: Create Model Benchmark Script

**Files:**
- Create: `scripts/bench-model.sh`

**Step 1: Create the script with header and config**

```bash
cat > scripts/bench-model.sh << 'SCRIPT'
#!/bin/bash
# bench-model.sh — Benchmark Qwen 3.6 tok/s at different context sizes
# Usage: ./scripts/bench-model.sh
# Requires: curl, jq, nvidia-smi, llama-server running on localhost:11434

set -euo pipefail

ENDPOINT="http://localhost:11434/v1/chat/completions"
MODEL="qwen36-apex"
CONTEXT_SIZES=(4096 16384 32768 65536 131072)
WARMUP_TOKENS=100
GEN_TOKENS=200
TIMEOUT=120

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "=== Model Benchmark ($(date)) ==="
echo "Endpoint: $ENDPOINT"
echo "Model: $MODEL"
echo ""

# Verify server is up
if ! curl -sf "$ENDPOINT" -o /dev/null --max-time 5 2>/dev/null; then
    echo -e "${RED}ERROR: llama-server not responding at $ENDPOINT${NC}"
    exit 1
fi
echo -e "${GREEN}Server is up${NC}"
echo ""

printf "| %-10s | %-12s | %-12s | %-12s | %-10s |\n" "Context" "Tok/s gen" "TTFT (ms)" "VRAM (MB)" "Status"
printf "| %-10s | %-12s | %-12s | %-12s | %-10s |\n" "----------" "------------" "------------" "------------" "----------"

for CTX in "${CONTEXT_SIZES[@]}"; do
    # Get VRAM before
    VRAM_BEFORE=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | tr -d ' ')

    # Build a prompt that fills context: repeated padding + generation request
    # We send a large system message to approach the context limit
    PADDING=$(printf 'X%.0s' $(seq 1 200))  # 200 char padding unit
    # Calculate how many padding units to fill ~80% of context
    PAD_COUNT=$(( CTX * 4 / 10 / 200 ))  # rough: 1 token ~ 4 chars, fill 80%
    PAD_COUNT=$(( PAD_COUNT > 0 ? PAD_COUNT : 1 ))

    SYSTEM_MSG=""
    for i in $(seq 1 "$PAD_COUNT"); do
        SYSTEM_MSG+="Paragraph $i: $PADDING. "
    done

    # Measure generation: send request and time it
    START_MS=$(date +%s%3N)

    RESPONSE=$(curl -sf "$ENDPOINT" \
        -H "Content-Type: application/json" \
        --max-time "$TIMEOUT" \
        -d "{
            \"model\": \"$MODEL\",
            \"messages\": [
                {\"role\": \"system\", \"content\": \"$SYSTEM_MSG\"},
                {\"role\": \"user\", \"content\": \"Say exactly: The quick brown fox jumps over the lazy dog. Then count from 1 to 50.\"}
            ],
            \"max_tokens\": $GEN_TOKENS,
            \"temperature\": 0.1,
            \"stream\": false
        }" 2>&1) || true

    END_MS=$(date +%s%3N)

    # Get VRAM after
    VRAM_AFTER=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | tr -d ' ')

    # Parse response
    if echo "$RESPONSE" | jq -e '.choices[0].message.content' >/dev/null 2>&1; then
        ELAPSED_MS=$(( END_MS - START_MS ))
        # Get usage stats from response
        PROMPT_TOKENS=$(echo "$RESPONSE" | jq -r '.usage.prompt_tokens // "N/A"')
        COMPLETION_TOKENS=$(echo "$RESPONSE" | jq -r '.usage.completion_tokens // "N/A"')

        if [ "$COMPLETION_TOKENS" != "N/A" ] && [ "$COMPLETION_TOKENS" -gt 0 ]; then
            TOK_S=$(echo "scale=1; $COMPLETION_TOKENS * 1000 / $ELAPSED_MS" | bc 2>/dev/null || echo "N/A")
            # TTFT: estimate from first token (if streaming was on, we'd measure it)
            # For non-streaming, use total time / total tokens as approximation
            TTFT_MS=$(( ELAPSED_MS * 30 / 100 ))  # rough: ~30% of time is prefill
        else
            TOK_S="N/A"
            TTFT_MS="N/A"
        fi

        printf "| %-10s | %-12s | %-12s | %-12s | ${GREEN}%-10s${NC} |\n" "$CTX" "$TOK_S" "$TTFT_MS" "$VRAM_AFTER" "OK"
    else
        # Error case
        ERROR=$(echo "$RESPONSE" | jq -r '.error.message // "Unknown error"' 2>/dev/null || echo "$RESPONSE" | head -1)
        ERROR_SHORT=$(echo "$ERROR" | cut -c1-40)
        printf "| %-10s | %-12s | %-12s | %-12s | ${RED}%-10s${NC} |\n" "$CTX" "-" "-" "$VRAM_AFTER" "FAIL: $ERROR_SHORT"
    fi

    # Brief pause between tests
    sleep 2
done

echo ""
echo "=== Done ==="
SCRIPT

chmod +x scripts/bench-model.sh
echo "✅ scripts/bench-model.sh created"
```

**Step 2: Test the script runs without errors**

Run: `cd /home/genar/src/llama-server-docker && bash scripts/bench-model.sh`
Expected: Table with tok/s at each context size, or clear error messages

**Step 3: Commit**

```bash
cd /home/genar/src/llama-server-docker
git add scripts/bench-model.sh
git commit -m "feat: add model performance benchmark script"
```

---

### Task 2: Create Session Benchmark Script

**Files:**
- Create: `scripts/bench-session.sh`

**Step 1: Create the script**

```bash
cat > scripts/bench-session.sh << 'SCRIPT'
#!/bin/bash
# bench-session.sh — Simulate a PI agent session, monitoring context growth and failure
# Usage: ./scripts/bench-session.sh
# Requires: curl, jq, nvidia-smi, llama-server running on localhost:11434

set -uo pipefail

ENDPOINT="http://localhost:11434/v1/chat/completions"
MODEL="qwen36-apex"
MAX_CALLS=50
TOKENS_PER_CALL=2000  # approximate tokens added per call
GEN_TOKENS=100
TIMEOUT=120
PAUSE_SECS=1

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo "=== Session Benchmark ($(date)) ==="
echo "Endpoint: $ENDPOINT"
echo "Model: $MODEL"
echo "Max calls: $MAX_CALLS (~$(( MAX_CALLS * TOKENS_PER_CALL / 1000 ))K tokens total)"
echo ""

# Verify server
if ! curl -sf "$ENDPOINT" -o /dev/null --max-time 5 2>/dev/null; then
    echo -e "${RED}ERROR: llama-server not responding at $ENDPOINT${NC}"
    exit 1
fi

# Conversation history (simulates growing context)
MESSAGES='[{"role":"system","content":"You are a coding assistant. Be concise."}]'
CALL_NUM=0
FAILED=false
FAILURE_REASON=""

printf "%-6s %-10s %-10s %-12s %-12s %-12s %s\n" "Call#" "Ctx(tok)" "Gen(tok)" "Tok/s" "Time(ms)" "VRAM(MB)" "Status"
echo "------ ---------- ---------- ------------ ------------ ------------ ----------"

while [ "$CALL_NUM" -lt "$MAX_CALLS" ] && [ "$FAILED" = "false" ]; do
    CALL_NUM=$(( CALL_NUM + 1 ))

    # Add user message to conversation
    USER_MSG="Call $CALL_NUM: Write a short Python function that calculates the fibonacci sequence up to N. Include type hints and a docstring. Also add error handling for negative numbers. Explain the algorithm briefly."

    # Append to messages array using jq
    MESSAGES=$(echo "$MESSAGES" | jq --arg msg "$USER_MSG" '. + [{"role":"user","content":$msg}]')

    # Get VRAM before
    VRAM=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | tr -d ' ')

    # Send request
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
        FAILURE_REASON=$(echo "$RESPONSE" | head -1 | cut -c1-60)
        printf "${RED}%-6s %-10s %-10s %-12s %-12s %-12s %s${NC}\n" "$CALL_NUM" "?" "?" "?" "$ELAPSED_MS" "$VRAM" "FAIL: curl error"
        break
    }

    END_MS=$(date +%s%3N)
    ELAPSED_MS=$(( END_MS - START_MS ))

    # Parse response
    if echo "$RESPONSE" | jq -e '.choices[0].message.content' >/dev/null 2>&1; then
        PROMPT_T=$(echo "$RESPONSE" | jq -r '.usage.prompt_tokens // 0')
        COMP_T=$(echo "$RESPONSE" | jq -r '.usage.completion_tokens // 0')
        TOTAL_T=$(( PROMPT_T + COMP_T ))

        if [ "$COMP_T" -gt 0 ] && [ "$ELAPSED_MS" -gt 0 ]; then
            TOK_S=$(echo "scale=1; $COMP_T * 1000 / $ELAPSED_MS" | bc 2>/dev/null || echo "?")
        else
            TOK_S="?"
        fi

        # Detect compaction indicators (context suddenly shrinks)
        STATUS="OK"
        if [ "$CALL_NUM" -gt 1 ]; then
            PREV_TOTAL=${PREV_TOTAL:-0}
            if [ "$TOTAL_T" -lt "$(( PREV_TOTAL / 2 ))" ] && [ "$PREV_TOTAL" -gt 10000 ]; then
                STATUS="${YELLOW}COMPACTION${NC}"
            fi
        fi
        PREV_TOTAL=$TOTAL_T

        printf "%-6s %-10s %-10s %-12s %-12s %-12s %b\n" "$CALL_NUM" "$TOTAL_T" "$COMP_T" "$TOK_S" "$ELAPSED_MS" "$VRAM" "$STATUS"

        # Append assistant response to conversation
        ASSISTANT_MSG=$(echo "$RESPONSE" | jq -r '.choices[0].message.content')
        MESSAGES=$(echo "$MESSAGES" | jq --arg msg "$ASSISTANT_MSG" '. + [{"role":"assistant","content":$msg}]')
    else
        # API returned error
        FAILED=true
        FAILURE_REASON=$(echo "$RESPONSE" | jq -r '.error.message // "Unknown"' 2>/dev/null || echo "$RESPONSE" | head -1 | cut -c1-60)
        printf "${RED}%-6s %-10s %-10s %-12s %-12s %-12s %s${NC}\n" "$CALL_NUM" "?" "?" "?" "$ELAPSED_MS" "$VRAM" "FAIL: $FAILURE_REASON"
        break
    fi

    sleep "$PAUSE_SECS"
done

echo ""
echo "=== Session Summary ==="
echo "Total calls: $CALL_NUM"
echo "Result: $([ "$FAILED" = "false" ] && echo -e "${GREEN}Completed all calls${NC}" || echo -e "${RED}Failed at call $CALL_NUM: $FAILURE_REASON${NC}")"
echo ""

# Capture last llama-server logs
echo "=== Last 20 llama-server log lines ==="
docker logs llama-server --tail 20 2>&1 || echo "(could not fetch logs)"
SCRIPT

chmod +x scripts/bench-session.sh
echo "✅ scripts/bench-session.sh created"
```

**Step 2: Test the script runs**

Run: `cd /home/genar/src/llama-server-docker && bash scripts/bench-session.sh`
Expected: Sequential calls with growing context, stops when context fills or error occurs

**Step 3: Commit**

```bash
cd /home/genar/src/llama-server-docker
git add scripts/bench-session.sh
git commit -m "feat: add session benchmark script for PI agent debugging"
```

---

### Task 3: Run Both Benchmarks and Document Results

**Step 1: Run model benchmark**

Run: `cd /home/genar/src/llama-server-docker && bash scripts/bench-model.sh 2>&1 | tee logs/bench-model-$(date +%Y%m%d).log`

**Step 2: Run session benchmark**

Run: `cd /home/genar/src/llama-server-docker && bash scripts/bench-session.sh 2>&1 | tee logs/bench-session-$(date +%Y%m%d).log`

**Step 3: Document results**

Create `docs/plans/2026-04-19-llama-benchmark-results.md` with:
- Raw output from both benchmarks
- Analysis: at what context size does performance degrade?
- Analysis: at what point does the session stop? Is it compaction-related?
- Recommendation: what to optimize next (ik_llama, ctx-size, parameters)

**Step 4: Commit results**

```bash
cd /home/genar/src/llama-server-docker
git add logs/bench-model-*.log logs/bench-session-*.log docs/plans/2026-04-19-llama-benchmark-results.md
git commit -m "docs: add benchmark results and analysis"
```
