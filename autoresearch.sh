#!/bin/bash
set -euo pipefail

# ==============================================================================
# Benchmark Suite: Optimal 3-Model Setup
# Tests models across 3 slots: Agent King, Deep Thinker, Speed Demon
# Requires llama-server running on localhost:11434
# ==============================================================================

BASE_URL="${LLAMA_BASE_URL:-http://localhost:11434/v1}"
MODEL="${1:-}"
SLOT="${2:-all}"
TIMEOUT="${BENCHMARK_TIMEOUT:-120}"
TMPDIR="${TMPDIR:-/tmp}"
METRICS_FILE="$TMPDIR/bench-$MODEL-$$.txt"
RESPONSES_DIR="$TMPDIR/bench-responses-$MODEL"
mkdir -p "$RESPONSES_DIR"

if [ -z "$MODEL" ]; then
    echo "Usage: $0 <model-alias> [slot]"
    echo "  slot: agent | thinker | speed | all (default: all)"
    echo ""
    echo "Available models:"
    curl -s "$BASE_URL/models" 2>/dev/null | jq -r '.data[].id' 2>/dev/null || echo "  (server not responding)"
    exit 1
fi

log() { echo "[bench] $1" >&2; }
metric() { echo "METRIC $1=$2"; }

# ==============================================================================
# call_model: Sends prompt to model, sets BENCH_* globals
# ==============================================================================
call_model() {
    local prompt="$1"
    local max_tokens="${2:-512}"
    local system_prompt="${3:-You are a helpful coding assistant. Respond concisely.}"
    local tmpfile="$TMPDIR/bench-call-$$.json"

    local json_body
    json_body=$(jq -n \
        --arg model "$MODEL" \
        --arg system "$system_prompt" \
        --arg prompt "$prompt" \
        --argjson max_tokens "$max_tokens" \
        '{
            model: $model,
            messages: [
                {role: "system", content: $system},
                {role: "user", content: $prompt}
            ],
            max_tokens: $max_tokens,
            temperature: 0.3,
            stream: false
        }')

    local start_time
    start_time=$(date +%s%3N)

    curl -s --max-time "$TIMEOUT" "$BASE_URL/chat/completions" \
        -H "Content-Type: application/json" \
        -d "$json_body" > "$tmpfile" 2>&1 || true

    local end_time
    end_time=$(date +%s%3N)

    BENCH_TOTAL_MS=$((end_time - start_time))
    BENCH_PROMPT_TOKENS=$(jq -r '.usage.prompt_tokens // 0' "$tmpfile")
    BENCH_COMPLETION_TOKENS=$(jq -r '.usage.completion_tokens // 0' "$tmpfile")
    # Extract content — some models (GLM) put response in reasoning_content
    local raw_content
    raw_content=$(jq -r '.choices[0].message.content // ""' "$tmpfile")
    if [ -z "$raw_content" ]; then
        raw_content=$(jq -r '.choices[0].message.reasoning_content // ""' "$tmpfile")
    fi
    echo "$raw_content" > "${tmpfile}.content"
    BENCH_CONTENT_FILE="${tmpfile}.content"
    BENCH_RESPONSE_FILE="${tmpfile}"
    BENCH_TEST_NAME=""  # Set by caller before calling call_model

    local error
    error=$(jq -r '.error.message // empty' "$tmpfile")
    if [ -n "$error" ]; then
        rm -f "$tmpfile"
        return 1
    fi

    if [ "$BENCH_COMPLETION_TOKENS" -eq 0 ] && [ ! -s "$BENCH_CONTENT_FILE" ]; then
        rm -f "$tmpfile"
        return 1
    fi

    BENCH_DECODE_TPS=0
    if [ "$BENCH_TOTAL_MS" -gt 0 ] && [ "$BENCH_COMPLETION_TOKENS" -gt 0 ]; then
        BENCH_DECODE_TPS=$(echo "scale=1; $BENCH_COMPLETION_TOKENS * 1000 / $BENCH_TOTAL_MS" | bc 2>/dev/null || echo "0")
    fi

    BENCH_PREFILL_MS=0
    if [ "$BENCH_COMPLETION_TOKENS" -gt 0 ]; then
        local decode_ms
        decode_ms=$(echo "scale=0; $BENCH_COMPLETION_TOKENS * 1000 / $BENCH_DECODE_TPS" | bc 2>/dev/null || echo "$BENCH_TOTAL_MS")
        BENCH_PREFILL_MS=$((BENCH_TOTAL_MS - decode_ms))
        [ "$BENCH_PREFILL_MS" -lt 0 ] && BENCH_PREFILL_MS=0
    fi

    # Save full response for inspection
    if [ -n "$BENCH_TEST_NAME" ] && [ -d "$RESPONSES_DIR" ]; then
        cp "$tmpfile" "$RESPONSES_DIR/$BENCH_TEST_NAME.json"
        cp "$BENCH_CONTENT_FILE" "$RESPONSES_DIR/$BENCH_TEST_NAME.txt"
    fi

    rm -f "$tmpfile"
    return 0
}

# Count how many keywords match in the content file
score_keywords() {
    local content_file="$1"; shift
    local score=0
    for kw in "$@"; do
        if grep -qi "$kw" "$content_file" 2>/dev/null; then
            score=$((score + 1))
        fi
    done
    echo $score
}

# ==============================================================================
# Test 1: Agent — Tool Use
# ==============================================================================
test_agent_tool_use() {
    log "Test: Tool Use / Function Calling"

    BENCH_TEST_NAME="tool_use"
    if ! call_model \
        'You have access to these tools: read_file(path), write_file(path, content), run_command(cmd).
Create a simple Express.js health check endpoint. Use the tools to:
1. Create server.js with a basic Express server with GET /health returning { status: "ok" }
Respond ONLY with the tool calls in JSON format.' \
        1024 "You are a coding agent. Respond with JSON tool calls only."; then
        log "FAIL Tool use: API error"
        metric agent_tool_use_score 0
        metric agent_tool_use_ms 0
        metric agent_tool_use_prefill_ms 0
        metric agent_tool_use_tps 0
        rm -f "$BENCH_CONTENT_FILE"
        return
    fi

    local score
    score=$(score_keywords "$BENCH_CONTENT_FILE" \
        "write_file" "run_command" "server" "express" "health" "listen")
    [ "$(wc -w < "$BENCH_CONTENT_FILE")" -gt 20 ] && score=$((score + 1))
    [ "$BENCH_COMPLETION_TOKENS" -gt 50 ] && score=$((score + 1))

    [ "$score" -ge 4 ] && log "PASS Tool use: score=$score" || log "WARN Tool use: score=$score"
    metric agent_tool_use_score $score
    metric agent_tool_use_ms $BENCH_TOTAL_MS
    metric agent_tool_use_prefill_ms $BENCH_PREFILL_MS
    metric agent_tool_use_tps $BENCH_DECODE_TPS
    rm -f "$BENCH_CONTENT_FILE"
}

# ==============================================================================
# Test 2: Agent — Bug Fix
# ==============================================================================
test_agent_bug_fix() {
    log "Test: Bug Fix"

    BENCH_TEST_NAME="bug_fix"
    if ! call_model \
        'Here is a Node.js function with a bug. Find it and provide the corrected code.

function fetchUserData(userId) {
  const response = await fetch("https://api.example.com/users/" + userId);
  const data = response.text();
  return data.items;
}

What is the bug and what is the corrected version?' \
        512 "You are an expert programmer. Identify bugs and provide corrected code."; then
        log "FAIL Bug fix: API error"
        metric agent_bug_fix_score 0
        metric agent_bug_fix_ms 0
        metric agent_bug_fix_prefill_ms 0
        metric agent_bug_fix_tps 0
        rm -f "$BENCH_CONTENT_FILE"
        return
    fi

    local score
    score=$(score_keywords "$BENCH_CONTENT_FILE" \
        "json" "await" ".text" "response")
    [ "$(wc -w < "$BENCH_CONTENT_FILE")" -gt 15 ] && score=$((score + 1))

    [ "$score" -ge 3 ] && log "PASS Bug fix: score=$score" || log "WARN Bug fix: score=$score"
    metric agent_bug_fix_score $score
    metric agent_bug_fix_ms $BENCH_TOTAL_MS
    metric agent_bug_fix_prefill_ms $BENCH_PREFILL_MS
    metric agent_bug_fix_tps $BENCH_DECODE_TPS
    rm -f "$BENCH_CONTENT_FILE"
}

# ==============================================================================
# Test 3: Agent — Multi-step Planning
# ==============================================================================
test_agent_planning() {
    log "Test: Multi-step Planning"

    BENCH_TEST_NAME="planning"
    if ! call_model \
        'I have a monorepo with 3 packages: api (Express), web (React), shared (types).
I need to add user authentication with JWT.
Give me a step-by-step implementation plan with specific files to create/modify in each package.
Format as a numbered list with file paths.' \
        768 "You are a senior software architect. Provide clear, actionable plans."; then
        log "FAIL Planning: API error"
        metric agent_plan_score 0
        metric agent_plan_ms 0
        metric agent_plan_prefill_ms 0
        metric agent_plan_tps 0
        rm -f "$BENCH_CONTENT_FILE"
        return
    fi

    local score
    score=$(score_keywords "$BENCH_CONTENT_FILE" \
        "jwt" "token" "shared" "api" "web" "login" "auth" "route")
    if grep -qE '^[[:space:]]*[0-9]+[\.\)]' "$BENCH_CONTENT_FILE" 2>/dev/null; then
        score=$((score + 1))
    fi
    [ "$(wc -w < "$BENCH_CONTENT_FILE")" -gt 60 ] && score=$((score + 1))

    [ "$score" -ge 4 ] && log "PASS Planning: score=$score" || log "WARN Planning: score=$score"
    metric agent_plan_score $score
    metric agent_plan_ms $BENCH_TOTAL_MS
    metric agent_plan_prefill_ms $BENCH_PREFILL_MS
    metric agent_plan_tps $BENCH_DECODE_TPS
    rm -f "$BENCH_CONTENT_FILE"
}

# ==============================================================================
# Test 4: Reasoning — Algorithm
# ==============================================================================
test_reasoning_algorithm() {
    log "Test: Reasoning - Algorithm"

    BENCH_TEST_NAME="algorithm"
    if ! call_model \
        'Implement a TypeScript function for longest common subsequence (LCS) of two strings.
Explain time and space complexity. Provide an optimized space version.' \
        1024 "You are an expert computer scientist and programmer."; then
        log "FAIL Algorithm: API error"
        metric think_algorithm_score 0
        metric think_algorithm_ms 0
        metric think_algorithm_prefill_ms 0
        metric think_algorithm_tps 0
        rm -f "$BENCH_CONTENT_FILE"
        return
    fi

    local score
    score=$(score_keywords "$BENCH_CONTENT_FILE" \
        "O(m" "dp" "typescript" "function" "subsequence" "optim")
    [ "$(wc -w < "$BENCH_CONTENT_FILE")" -gt 60 ] && score=$((score + 1))

    [ "$score" -ge 3 ] && log "PASS Algorithm: score=$score" || log "WARN Algorithm: score=$score"
    metric think_algorithm_score $score
    metric think_algorithm_ms $BENCH_TOTAL_MS
    metric think_algorithm_prefill_ms $BENCH_PREFILL_MS
    metric think_algorithm_tps $BENCH_DECODE_TPS
    rm -f "$BENCH_CONTENT_FILE"
}

# ==============================================================================
# Test 5: Reasoning — Debugging
# ==============================================================================
test_reasoning_debugging() {
    log "Test: Reasoning - Debugging"

    BENCH_TEST_NAME="debugging"
    if ! call_model \
        'A Node.js app crashes with "heap out of memory" after 24-48 hours in production.
Processes 10K requests/hour, uses Express, PostgreSQL (pg pool), and Redis. Memory gradually increases.
What are the most likely causes and how would you diagnose each? Be specific.' \
        768 "You are an expert DevOps engineer and Node.js performance specialist."; then
        log "FAIL Debugging: API error"
        metric think_debug_score 0
        metric think_debug_ms 0
        metric think_debug_prefill_ms 0
        metric think_debug_tps 0
        rm -f "$BENCH_CONTENT_FILE"
        return
    fi

    local score
    score=$(score_keywords "$BENCH_CONTENT_FILE" \
        "memory" "leak" "heap" "pool" "event" "listener" "profil" "diagnos")
    [ "$(wc -w < "$BENCH_CONTENT_FILE")" -gt 60 ] && score=$((score + 1))

    [ "$score" -ge 3 ] && log "PASS Debugging: score=$score" || log "WARN Debugging: score=$score"
    metric think_debug_score $score
    metric think_debug_ms $BENCH_TOTAL_MS
    metric think_debug_prefill_ms $BENCH_PREFILL_MS
    metric think_debug_tps $BENCH_DECODE_TPS
    rm -f "$BENCH_CONTENT_FILE"
}

# ==============================================================================
# Test 6: Speed — Quick Q&A
# ==============================================================================
test_speed_quick_qa() {
    log "Test: Speed - Quick QA"

    BENCH_TEST_NAME="quick_qa"
    if ! call_model \
        'What is the difference between let, const, and var in JavaScript? Answer in 2-3 sentences.' \
        256 "You are a helpful assistant. Be concise."; then
        log "FAIL Quick QA: API error"
        metric speed_qa_score 0
        metric speed_qa_ms 0
        metric speed_qa_prefill_ms 0
        metric speed_qa_tps 0
        rm -f "$BENCH_CONTENT_FILE"
        return
    fi

    local score
    score=$(score_keywords "$BENCH_CONTENT_FILE" \
        "let" "const" "var" "scope" "hoist" "block")
    [ "$BENCH_TOTAL_MS" -lt 5000 ] && score=$((score + 1))
    [ "$BENCH_TOTAL_MS" -lt 3000 ] && score=$((score + 1))

    log "INFO Quick QA: score=$score (${BENCH_TOTAL_MS}ms, ${BENCH_DECODE_TPS} t/s)"
    metric speed_qa_score $score
    metric speed_qa_ms $BENCH_TOTAL_MS
    metric speed_qa_prefill_ms $BENCH_PREFILL_MS
    metric speed_qa_tps $BENCH_DECODE_TPS
    rm -f "$BENCH_CONTENT_FILE"
}

# ==============================================================================
# Test 7: Speed — Code Completion
# ==============================================================================
test_speed_completion() {
    log "Test: Speed - Code Completion"

    BENCH_TEST_NAME="code_completion"
    if ! call_model \
        'Complete this Python function:

def merge_sorted_arrays(arr1, arr2):
    """Merge two sorted arrays into one sorted array."""' \
        256 "You are a Python expert. Only output the completed function code, no explanation."; then
        log "FAIL Completion: API error"
        metric speed_completion_score 0
        metric speed_completion_ms 0
        metric speed_completion_prefill_ms 0
        metric speed_completion_tps 0
        rm -f "$BENCH_CONTENT_FILE"
        return
    fi

    local score
    score=$(score_keywords "$BENCH_CONTENT_FILE" \
        "while" "return" "append" "sort" "merged")
    if grep -q 'def ' "$BENCH_CONTENT_FILE" 2>/dev/null; then
        score=$((score + 1))
    fi

    log "INFO Completion: score=$score (${BENCH_TOTAL_MS}ms, ${BENCH_DECODE_TPS} t/s)"
    metric speed_completion_score $score
    metric speed_completion_ms $BENCH_TOTAL_MS
    metric speed_completion_prefill_ms $BENCH_PREFILL_MS
    metric speed_completion_tps $BENCH_DECODE_TPS
    rm -f "$BENCH_CONTENT_FILE"
}

# ==============================================================================
# Test 8: Reliability — Hallucination Check
# ==============================================================================
test_reliability() {
    log "Test: Reliability - Hallucination Check"

    BENCH_TEST_NAME="reliability"
    if ! call_model \
        'In React 22, what is the new useSuperState hook and how does it differ from useState?
Provide the API signature and a code example.' \
        256 "You are a React expert with deep knowledge of all versions."; then
        log "FAIL Reliability: API error"
        metric reliability_score 0
        rm -f "$BENCH_CONTENT_FILE"
        return
    fi

    # Good: model recognizes it does not exist
    local good_score
    good_score=$(score_keywords "$BENCH_CONTENT_FILE" \
        "does not exist" "not exist" "no such" "not a hook" "not released" \
        "fictional" "made up" "do not know" "not aware" "as of" "current" \
        "latest" "does not have" "not a feature" "not available")

    # Bad: model makes up details
    local bad_score
    bad_score=$(score_keywords "$BENCH_CONTENT_FILE" "useSuperState")

    local score=$((good_score * 2 - bad_score))
    [ "$score" -lt 0 ] && score=0

    [ "$score" -ge 4 ] && log "PASS Reliability: score=$score" || log "WARN Reliability: score=$score"
    metric reliability_score $score
    rm -f "$BENCH_CONTENT_FILE"
}

# ==============================================================================
# Main
# ==============================================================================
log "=========================================="
log "Benchmark: model=$MODEL slot=$SLOT"
log "=========================================="

if ! curl -s --max-time 5 "$BASE_URL/models" > /dev/null 2>&1; then
    echo "ERROR: llama-server not responding at $BASE_URL"
    exit 1
fi

if ! curl -s "$BASE_URL/models" | jq -e --arg m "$MODEL" '.data[] | select(.id == $m)' > /dev/null 2>&1; then
    echo "ERROR: model '$MODEL' not found. Available:"
    curl -s "$BASE_URL/models" | jq -r '.data[].id' | sed 's/^/  /'
    exit 1
fi

log "Model found. Running tests..."

# Run tests - output goes to both stdout (for run_experiment) and metrics file
> "$METRICS_FILE"
(
case "$SLOT" in
    agent)
        test_agent_tool_use
        test_agent_bug_fix
        test_agent_planning
        ;;
    thinker)
        test_reasoning_algorithm
        test_reasoning_debugging
        test_reliability
        ;;
    speed)
        test_speed_quick_qa
        test_speed_completion
        test_reliability
        ;;
    all)
        test_agent_tool_use
        test_agent_bug_fix
        test_agent_planning
        test_reasoning_algorithm
        test_reasoning_debugging
        test_speed_quick_qa
        test_speed_completion
        test_reliability
        ;;
    *)
        echo "ERROR: Unknown slot: $SLOT. Use: agent, thinker, speed, all"
        exit 1
        ;;
esac
) 2>&1 | tee "$METRICS_FILE"

# Compute composite from metrics file
compute_composite() {
    local agent_total=0 agent_max=0
    local think_total=0 think_max=0
    local speed_total=0 speed_max=0
    local speed_ms_total=0 speed_ms_count=0
    local reliability=0

    while IFS='=' read -r key value; do
        key="${key#METRIC }"
        case "$key" in
            agent_tool_use_score)   agent_total=$((agent_total + value)); agent_max=$((agent_max + 8)) ;;
            agent_bug_fix_score)    agent_total=$((agent_total + value)); agent_max=$((agent_max + 5)) ;;
            agent_plan_score)       agent_total=$((agent_total + value)); agent_max=$((agent_max + 10)) ;;
            think_algorithm_score)  think_total=$((think_total + value)); think_max=$((think_max + 7)) ;;
            think_debug_score)      think_total=$((think_total + value)); think_max=$((think_max + 9)) ;;
            speed_qa_score)         speed_total=$((speed_total + value)); speed_max=$((speed_max + 8)) ;;
            speed_qa_ms)            speed_ms_total=$((speed_ms_total + value)); speed_ms_count=$((speed_ms_count + 1)) ;;
            speed_completion_score) speed_total=$((speed_total + value)); speed_max=$((speed_max + 6)) ;;
            speed_completion_ms)    speed_ms_total=$((speed_ms_total + value)); speed_ms_count=$((speed_ms_count + 1)) ;;
            reliability_score)      reliability=$value ;;
        esac
    done < "$METRICS_FILE"

    local agent_pct=0 think_pct=0 speed_pct=0 rel_pct=0
    [ "$agent_max" -gt 0 ] && agent_pct=$((agent_total * 100 / agent_max))
    [ "$think_max" -gt 0 ] && think_pct=$((think_total * 100 / think_max))
    [ "$speed_max" -gt 0 ] && speed_pct=$((speed_total * 100 / speed_max))
    rel_pct=$((reliability * 20))
    [ "$rel_pct" -gt 100 ] && rel_pct=100

    # Time penalty: average speed task time > 5s penalizes score
    # < 2s = no penalty, 5s = 20% penalty, 10s+ = 50% penalty
    local avg_speed_ms=0
    if [ "$speed_ms_count" -gt 0 ]; then
        avg_speed_ms=$((speed_ms_total / speed_ms_count))
    fi
    local speed_time_penalty=0
    if [ "$avg_speed_ms" -gt 2000 ]; then
        speed_time_penalty=$(( (avg_speed_ms - 2000) / 160 ))
        [ "$speed_time_penalty" -gt 50 ] && speed_time_penalty=50
    fi
    speed_pct=$((speed_pct * (100 - speed_time_penalty) / 100))

    local composite=$(( agent_pct * 40 / 100 + think_pct * 25 / 100 + speed_pct * 20 / 100 + rel_pct * 15 / 100 ))

    metric composite_score $composite
    metric agent_quality_pct $agent_pct
    metric think_quality_pct $think_pct
    metric speed_quality_pct $speed_pct
    metric reliability_pct $rel_pct
    metric avg_speed_ms $avg_speed_ms
    metric speed_time_penalty $speed_time_penalty
}

compute_composite
rm -f "$METRICS_FILE"

log "=========================================="
log "Benchmark complete: model=$MODEL slot=$SLOT"
log "=========================================="
