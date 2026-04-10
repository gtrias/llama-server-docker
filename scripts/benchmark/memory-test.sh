#!/bin/bash
set -euo pipefail

# ==============================================================================
# Memory Consistency Test: Can the model remember instructions under context pressure?
#
# Plants specific facts/constraints in early conversation rounds, then tests
# recall after 15-25 rounds of unrelated work. Measures at which context size
# the model starts "forgetting" instructions — the real cause of
# "I told it TypeScript but it switched to JavaScript 20 minutes later."
# ==============================================================================

BASE_URL="${LLAMA_BASE_URL:-http://localhost:11434/v1}"
MODEL="${1:?Usage: $0 <model-alias> [output-dir]}"
OUTPUT_DIR="${2:-/tmp/memory-test}"
NUM_ROUNDS="${NUM_ROUNDS:-25}"

mkdir -p "$OUTPUT_DIR/$MODEL"

log() { echo "[memory] $1" >&2; }
timestamp() { date +%s%3N; }

# ==============================================================================
# Call model helper
# ==============================================================================
call_model() {
    local messages_json="$1" max_tokens="${2:-512}"

    local start=$(timestamp)
    local resp_file=$(mktemp)

    curl -s --max-time 120 "$BASE_URL/chat/completions" \
        -H "Content-Type: application/json" \
        -d "$(jq -n \
            --arg model "$MODEL" \
            --argjson messages "$messages_json" \
            --argjson max_tokens "$max_tokens" \
            '{model: $model, messages: $messages, max_tokens: $max_tokens, temperature: 0.2, stream: false}')" > "$resp_file" 2>&1

    local end=$(timestamp)
    local total_ms=$((end - start))

    local content=$(jq -r '.choices[0].message.content // ""' "$resp_file" 2>/dev/null)
    local reasoning=$(jq -r '.choices[0].message.reasoning_content // ""' "$resp_file" 2>/dev/null)
    if [ -z "$content" ] && [ -n "$reasoning" ]; then
        content="$reasoning"
    fi

    local prompt_t=$(jq -r '.usage.prompt_tokens // 0' "$resp_file" 2>/dev/null)
    local completion_t=$(jq -r '.usage.completion_tokens // 0' "$resp_file" 2>/dev/null)

    rm -f "$resp_file"

    echo "$content"
    echo "___META___"
    echo "total_ms=$total_ms"
    echo "prompt_tokens=$prompt_t"
    echo "completion_tokens=$completion_t"
    echo "content_len=${#content}"
}

# ==============================================================================
# Memory items: facts planted in conversation, tested later
#
# Each item has: round to plant, round to test, question, expected_answer (regex),
# and the planting message (conversation context)
# ==============================================================================

# Phase 1: Plant facts (rounds 1-6)
# Phase 2: Filler work (rounds 7-18) — builds context pressure
# Phase 3: Test recall (rounds 19-25)

declare -a PLANT_ROUNDS=(1 2 3 4 5 6)
declare -a PLANT_MESSAGES=(
    # 1: Name constraint (instruction)
    "I'm working on a project called **DataForge**. The project name is important — always use 'DataForge' when referring to it, never 'DataForge Pro' or 'DataForge Lite'."

    # 2: Language constraint (instruction)
    "All code in this project must be written in **TypeScript**. Do not suggest JavaScript, Python, or any other language. If I ask for code, always write TypeScript."

    # 3: Factual detail (embedded in conversation)
    "The database connection string for staging is: postgresql://admin:forge2024@db.staging.dataforge.io:5432/dataforge. Keep this safe — I'll need it later."

    # 4: Architecture constraint (instruction)
    "The project uses a specific folder structure. All API routes must go in /src/routes/, all database queries in /src/db/, and all types in /src/types/. Never put code outside these folders."

    # 5: Preference/style (instruction)
    "I prefer functional programming style. Use const, arrow functions, map/filter/reduce, and immutable patterns. Avoid classes and mutation. When showing code examples, always use this style."

    # 6: Another factual detail
    "My team lead's email is **sarah.chen@dataforge.io** and her Slack handle is **@schen**. I need to CC her on any deployment notifications."
)

# Fillers: unrelated tasks to build context pressure
declare -a FILLER_MESSAGES=(
    "Can you explain the difference between optimistic and pessimistic concurrency control in databases? Give me a concise explanation."
    "What are the main differences between GraphQL and REST? List 3 pros and 3 cons of each."
    "Explain what eventual consistency means in distributed systems. Give a real-world example."
    "What is the CAP theorem? Explain each of the three properties with a brief example."
    "Describe the difference between server-side rendering and client-side rendering. When would you use each?"
    "What are environment variables and why are they important for application configuration? Give examples."
    "Explain the concept of database indexing. When should you add an index and when should you avoid it?"
    "What is a reverse proxy and how does it differ from a load balancer? Give use cases for each."
    "Describe the difference between authentication and authorization. Give a concrete example of each."
    "What is connection pooling and why is it useful for database performance? Explain briefly."
    "Explain what a webhook is and how it differs from a regular API call. Give an example."
    "What is idempotency? Why is it important for REST API design? Give examples of idempotent vs non-idempotent operations."
)

# Tests: questions that check if the model remembers
declare -a TEST_QUESTIONS=(
    # Test 1 (round 19): Project name
    "What is the name of the project I'm working on?"

    # Test 2 (round 20): Language constraint — ask for code
    "Write a simple function that validates an email address. Just the function, no explanation."

    # Test 3 (round 21): Database connection string
    "What was the staging database connection string I shared earlier? Give me the exact string."

    # Test 4 (round 22): Folder structure
    "I need to add a new API endpoint for user authentication. Where should I put the route handler file? Give me the exact folder path."

    # Test 5 (round 23): Programming style
    "Write a function that takes an array of numbers and returns only the even ones, doubled. Show me your approach."

    # Test 6 (round 24): Team lead info
    "I need to notify my team lead about a deployment. What is her email address and Slack handle?"

    # Test 7 (round 25): Composite — multiple facts at once
    "Quick summary: what is the project called, what language do we use, and what is the staging database host?"
)

# Expected answers (regex patterns for scoring)
declare -a TEST_PATTERNS=(
    "DataForge"                          # Project name
    "typescript|TypeScript|interface|:.*function|:.*const"   # Language — must be TS, not JS
    "postgresql://admin:forge2024@db.staging.dataforge.io"  # DB string
    "/src/routes/"                        # Folder structure
    "const.*=>|arrow|filter|map"         # Functional style
    "sarah.chen|schen"                    # Team lead (relaxed pattern)
    "DataForge"                            # Composite — just check project name recalled
)

declare -a TEST_POINTS=(5 10 10 10 10 10 15)

# ==============================================================================
# Run the memory test
# ==============================================================================

log "Starting memory consistency test for $MODEL ($NUM_ROUNDS rounds)"

MESSAGES=$(jq -n '[]')

round=0
total_prompt_tokens=0
memory_score=0
memory_max=0
for p in "${TEST_POINTS[@]}"; do memory_max=$((memory_max + p)); done

CSV_HEADER="round,type,prompt_tokens,completion_tokens,total_ms,memory_result"
echo "$CSV_HEADER" > "$OUTPUT_DIR/$MODEL/memory_results.csv"

# Phase 1: Plant facts (rounds 1-6)
log ""
log "=== PHASE 1: Planting facts ==="
for i in "${!PLANT_MESSAGES[@]}"; do
    round=$((round + 1))
    msg="${PLANT_MESSAGES[$i]}"

    MESSAGES=$(echo "$MESSAGES" | jq --arg msg "$msg" '. + [{role: "user", content: $msg}]')

    result=$(call_model "$MESSAGES" 256)
    content=$(echo "$result" | sed '/^___META___$/,$ d')
    meta=$(echo "$result" | sed -n '/^___META___$/,$ p' | tail -n +2)
    eval "$meta" 2>/dev/null || true
    content=${content:-}

    MESSAGES=$(echo "$MESSAGES" | jq --arg c "$content" '. + [{role: "assistant", content: $c}]')
    total_prompt_tokens=$((total_prompt_tokens + prompt_tokens))

    log "  Planted fact $((i+1)) (round $round): $(echo "$msg" | head -c 60)..."
    echo "$round,plant,$prompt_tokens,${completion_tokens:-0},${total_ms:-0},-" >> "$OUTPUT_DIR/$MODEL/memory_results.csv"
    sleep 0.5
done

# Phase 2: Filler work (rounds 7-18)
log ""
log "=== PHASE 2: Building context pressure ==="
filler_idx=0
while [ $round -lt 19 ] && [ $filler_idx -lt ${#FILLER_MESSAGES[@]} ]; do
    round=$((round + 1))
    msg="${FILLER_MESSAGES[$filler_idx]}"

    MESSAGES=$(echo "$MESSAGES" | jq --arg msg "$msg" '. + [{role: "user", content: $msg}]')

    result=$(call_model "$MESSAGES" 384)
    content=$(echo "$result" | sed '/^___META___$/,$ d')
    meta=$(echo "$result" | sed -n '/^___META___$/,$ p' | tail -n +2)
    eval "$meta" 2>/dev/null || true
    content=${content:-}

    MESSAGES=$(echo "$MESSAGES" | jq --arg c "$content" '. + [{role: "assistant", content: $c}]')
    total_prompt_tokens=$((total_prompt_tokens + prompt_tokens))

    log "  Filler $filler_idx (round $round): ${prompt_tokens}p tokens, ${total_ms:-0}ms"
    echo "$round,filler,$prompt_tokens,${completion_tokens:-0},${total_ms:-0},-" >> "$OUTPUT_DIR/$MODEL/memory_results.csv"
    sleep 0.5
    filler_idx=$((filler_idx + 1))
done

# Phase 3: Test recall (rounds 19-25)
log ""
log "=== PHASE 3: Testing memory (context now ~${total_prompt_tokens} tokens) ==="
test_idx=0
for test_round in $(seq 19 $NUM_ROUNDS); do
    if [ $test_idx -ge ${#TEST_QUESTIONS[@]} ]; then break; fi

    round=$test_round
    question="${TEST_QUESTIONS[$test_idx]}"
    pattern="${TEST_PATTERNS[$test_idx]}"
    points=${TEST_POINTS[$test_idx]}

    MESSAGES=$(echo "$MESSAGES" | jq --arg q "$question" '. + [{role: "user", content: $q}]')

    result=$(call_model "$MESSAGES" 512)
    content=$(echo "$result" | sed '/^___META___$/,$ d')
    meta=$(echo "$result" | sed -n '/^___META___$/,$ p' | tail -n +2)
    eval "$meta" 2>/dev/null || true
    content=${content:-}

    MESSAGES=$(echo "$MESSAGES" | jq --arg c "$content" '. + [{role: "assistant", content: $c}]')
    total_prompt_tokens=$((total_prompt_tokens + prompt_tokens))

    # Check if the answer contains the expected pattern
    test_result="FAIL"
    if echo "$content" | grep -qiE "$pattern"; then
        test_result="PASS"
        memory_score=$((memory_score + points))
        log "  ✓ Test $((test_idx+1)) (+$points pts): $question"
    else
        log "  ✗ Test $((test_idx+1)) (0/$points pts): $question"
        log "    Expected pattern: $pattern"
        log "    Got: $(echo "$content" | head -c 150)"
    fi

    echo "$round,test,$prompt_tokens,${completion_tokens:-0},${total_ms:-0},$test_result" >> "$OUTPUT_DIR/$MODEL/memory_results.csv"
    sleep 0.5
    test_idx=$((test_idx + 1))
done

# ==============================================================================
# Final analysis
# ==============================================================================

pct=$((memory_score * 100 / memory_max))

log ""
log "=========================================="
log "  MEMORY CONSISTENCY TEST: $MODEL"
log "=========================================="
log "  Score:    $memory_score / $memory_max ($pct%)"
log "  Context:  ~${total_prompt_tokens} prompt tokens at test time"
log "  Rounds:   $round"
log "=========================================="

# Categorize
if [ "$pct" -ge 90 ]; then
    grade="EXCELLENT"
    grade_desc="Model maintains instruction fidelity under heavy context"
elif [ "$pct" -ge 70 ]; then
    grade="GOOD"
    grade_desc="Most instructions retained, some slip through at long context"
elif [ "$pct" -ge 50 ]; then
    grade="FAIR"
    grade_desc="Significant forgetting — will need reminders in long sessions"
elif [ "$pct" -ge 25 ]; then
    grade="POOR"
    grade_desc="Frequent instruction loss — unreliable for multi-step agent work"
else
    grade="CRITICAL"
    grade_desc="Cannot maintain context — unsuitable for agent workflows"
fi

log "  Grade:    $grade"
log "  Detail:   $grade_desc"
log "=========================================="

# Save conversation
echo "$MESSAGES" | jq '.' > "$OUTPUT_DIR/$MODEL/memory_conversation.json" 2>/dev/null

# Per-test breakdown
log ""
log "  Per-test breakdown:"
test_idx=0
for test_round in $(seq 19 $NUM_ROUNDS); do
    if [ $test_idx -ge ${#TEST_QUESTIONS[@]} ]; then break; fi
    result_line=$(grep "^$test_round,test," "$OUTPUT_DIR/$MODEL/memory_results.csv" | tail -1)
    result_status=$(echo "$result_line" | awk -F, '{print $6}')
    status_icon="✗"
    if [ "$result_status" = "PASS" ]; then status_icon="✓"; fi
    log "    $status_icon Test $((test_idx+1)): ${TEST_PATTERNS[$test_idx]} (${TEST_POINTS[$test_idx]}pts)"
    test_idx=$((test_idx + 1))
done

# Emit metrics
echo "METRIC memory_total_score=$memory_score"
echo "METRIC memory_max_score=$memory_max"
echo "METRIC memory_pct=$pct"
echo "METRIC memory_grade=$grade"
echo "METRIC memory_context_tokens=$total_prompt_tokens"
echo "METRIC memory_rounds=$round"
