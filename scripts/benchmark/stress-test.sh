#!/bin/bash
set -euo pipefail

# ==============================================================================
# Long-Context Stress Test: How does the model behave when context fills up?
#
# Simulates a real Pi session:
# 1. Start with system prompt + instructions
# 2. Do 20 rounds of increasingly complex tool-call conversations
# 3. At each round, measure: response time, prompt tokens, VRAM, behavior
# 4. Score: consistency, degradation detection, crash recovery
#
# Also monitors llama.cpp health: VRAM usage, KV cache pressure
# ==============================================================================

BASE_URL="${LLAMA_BASE_URL:-http://localhost:11434/v1}"
MODEL="${1:?Usage: $0 <model-alias> [output-dir]}"
OUTPUT_DIR="${2:-/tmp/stress-test}"
NUM_ROUNDS="${NUM_ROUNDS:-20}"

mkdir -p "$OUTPUT_DIR/$MODEL"

log() { echo "[stress] $1" >&2; }
timestamp() { date +%s%3N; }

# ==============================================================================
# Helper: call model and measure performance
# ==============================================================================
call_model() {
    local messages_json="$1" max_tokens="${2:-2048}" temperature="${3:-0.3}"

    local start=$(timestamp)
    local resp_file=$(mktemp)
    local curl_err_file=$(mktemp)

    curl -s --max-time 120 "$BASE_URL/chat/completions" \
        -H "Content-Type: application/json" \
        -d "$(jq -n \
            --arg model "$MODEL" \
            --argjson messages "$messages_json" \
            --argjson max_tokens "$max_tokens" \
            --argjson temp "$temperature" \
            '{
                model: $model,
                messages: $messages,
                max_tokens: $max_tokens,
                temperature: $temp,
                stream: false
            }')" > "$resp_file" 2>"$curl_err_file"

    local end=$(timestamp)
    local total_ms=$((end - start))

    # Parse response
    local content=$(jq -r '.choices[0].message.content // ""' "$resp_file" 2>/dev/null)
    local reasoning=$(jq -r '.choices[0].message.reasoning_content // ""' "$resp_file" 2>/dev/null)
    local finish=$(jq -r '.choices[0].finish_reason // ""' "$resp_file" 2>/dev/null)
    local prompt_t=$(jq -r '.usage.prompt_tokens // 0' "$resp_file" 2>/dev/null)
    local completion_t=$(jq -r '.usage.completion_tokens // 0' "$resp_file" 2>/dev/null)
    local total_t=$(jq -r '.usage.total_tokens // 0' "$resp_file" 2>/dev/null)
    local eval_ms=$(jq -r '.timings.predicted_ms // 0' "$resp_file" 2>/dev/null)
    local prompt_ms=$(jq -r '.timings.prompt_ms // 0' "$resp_file" 2>/dev/null)

    # Use reasoning_content as fallback
    if [ -z "$content" ] && [ -n "$reasoning" ]; then
        content="$reasoning"
    fi

    rm -f "$resp_file" "$curl_err_file"

    echo "$content"
    echo "___META___"
    echo "total_ms=$total_ms"
    echo "prompt_ms=$prompt_ms"
    echo "eval_ms=$eval_ms"
    echo "finish_reason=$finish"
    echo "prompt_tokens=$prompt_t"
    echo "completion_tokens=$completion_t"
    echo "total_tokens=$total_t"
    echo "content_len=${#content}"
}

# ==============================================================================
# Helper: get VRAM usage from nvidia-smi (inside Docker)
# ==============================================================================
get_vram() {
    docker exec llama-server nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 | awk -F', ' '{print $1}'
}

get_vram_total() {
    docker exec llama-server nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1
}

# ==============================================================================
# Build the conversation simulation
# ==============================================================================

# System prompt that requires consistent tool format
SYSTEM_PROMPT='You are a coding assistant working on a Python project. You must ALWAYS respond with valid JSON tool calls in this exact format:

For reading files:
{"tool": "read_file", "path": "/path/to/file"}

For writing files:
{"tool": "write_file", "path": "/path/to/file", "content": "file contents here"}

For running commands:
{"tool": "bash", "command": "shell command here"}

For responding to the user:
{"tool": "respond", "message": "your response here"}

RULES:
- Every response MUST be exactly ONE valid JSON object
- NEVER include explanations outside the JSON
- NEVER use markdown formatting
- NEVER stop producing JSON format mid-conversation
- ALWAYS use the tool format, even for simple responses
- NEVER produce empty responses
- If unsure, use {"tool": "respond", "message": "I need more information"}'

# Tasks that simulate a real development session — progressively build up context
declare -a TASKS=(
    # Round 1-5: Setup and exploration
    '{"tool": "respond", "message": "I need to set up a new Python project. What should I create first?"}'
    '{"tool": "bash", "command": "ls -la"}'
    '{"tool": "read_file", "path": "/etc/os-release"}'
    '{"tool": "respond", "message": "Now create a simple calculator module with add, subtract, multiply, divide functions"}'
    '{"tool": "write_file", "path": "calculator.py", "content": "# Calculator module\\ndef add(a, b): return a + b\\ndef subtract(a, b): return a - b\\ndef multiply(a, b): return a * b\\ndef divide(a, b):\\n    if b == 0:\\n        raise ValueError(\"Cannot divide by zero\")\\n    return a / b"}'

    # Round 6-10: Adding complexity
    '{"tool": "respond", "message": "Great! Now add unit tests for the calculator. Include edge cases like division by zero."}'
    '{"tool": "bash", "command": "python3 -c \"import calculator; print(calculator.add(2,3))\""}'
    '{"tool": "respond", "message": "The tests are failing because of an import error. Check the test file and the calculator module."}'
    '{"tool": "read_file", "path": "test_calculator.py"}'
    '{"tool": "write_file", "path": "test_calculator.py", "content": "import unittest\\nimport calculator\\n\\nclass TestCalculator(unittest.TestCase):\\n    def test_add(self): self.assertEqual(calculator.add(2,3), 5)\\n    def test_subtract(self): self.assertEqual(calculator.subtract(10,4), 6)\\n    def test_multiply(self): self.assertEqual(calculator.multiply(3,7), 21)\\n    def test_divide(self): self.assertEqual(calculator.divide(15,3), 5.0)\\n    def test_divide_by_zero(self): self.assertRaises(ValueError, calculator.divide, 10, 0)\\n\\nif __name__ == \"__main__\": unittest.main()"}'

    # Round 11-15: Deeper work
    '{"tool": "respond", "message": "Now add a history feature that logs all operations. Modify calculator.py to track operations in a list."}'
    '{"tool": "bash", "command": "python3 -m pytest test_calculator.py -v"}'
    '{"tool": "respond", "message": "The history feature broke the existing tests. The tests expect clean return values but now the function returns a tuple. Fix this by keeping the return value the same and storing history separately."}'
    '{"tool": "read_file", "path": "calculator.py"}'
    '{"tool": "respond", "message": "Perfect. Now create a CLI interface using argparse that lets users run calculator operations from the command line. Support add, subtract, multiply, divide subcommands."}'

    # Round 16-20: Late session — testing if model still follows format
    '{"tool": "bash", "command": "python3 calculator_cli.py add 15 27"}'
    '{"tool": "respond", "message": "Add error handling for invalid numeric input in the CLI. Catch ValueError and show a friendly message."}'
    '{"tool": "respond", "message": "Now add a --history flag that shows the last 10 operations from the history."}'
    '{"tool": "respond", "message": "One more thing: add logging to the calculator module using Python logging. Log each operation at INFO level and errors at ERROR level."}'
    '{"tool": "respond", "message": "Finally, create a README.md with usage instructions, examples, and installation steps. Then run all tests one more time to confirm everything works."}'
)

# ==============================================================================
# Run the stress test
# ==============================================================================

log "Starting long-context stress test for $MODEL ($NUM_ROUNDS rounds)"
log "VRAM at start: $(get_vram)MiB / $(get_vram_total)MiB"

# Initialize conversation
MESSAGES=$(jq -n \
    --arg system "$SYSTEM_PROMPT" \
    '[{role: "system", content: $system}]')

# Results tracking
declare -a results=()
total_prompt_tokens=0
total_completion_tokens=0
total_time_ms=0
format_errors=0
empty_responses=0
loops_detected=0
crashes=0
vram_samples=""

CSV_HEADER="round,prompt_tokens,completion_tokens,total_tokens,content_len,prompt_ms,eval_ms,total_ms,finish_reason,vram_used,format_ok,loop_detected"
echo "$CSV_HEADER" > "$OUTPUT_DIR/$MODEL/stress_results.csv"

for i in $(seq 1 $NUM_ROUNDS); do
    task_idx=$((i - 1))
    task="${TASKS[$task_idx]}"

    log "--- Round $i / $NUM_ROUNDS (prompt so far: ~$total_prompt_tokens tokens) ---"

    # Get VRAM before call
    vram_before=$(get_vram)

    # Add the task to conversation
    MESSAGES=$(echo "$MESSAGES" | jq --arg task "$task" '. + [{role: "user", content: $task}]')

    # Call model
    result=$(call_model "$MESSAGES" 2048 0.3)

    # Parse metadata
    meta=$(echo "$result" | sed -n '/^___META___$/,$ p' | tail -n +2)
    content=$(echo "$result" | sed '/^___META___$/,$ d')

    eval "$meta" 2>/dev/null || true
    content=${content:-}

    # Add response to conversation
    if [ -n "$content" ]; then
        MESSAGES=$(echo "$MESSAGES" | jq --arg content "$content" '. + [{role: "assistant", content: $content}]')
    else
        MESSAGES=$(echo "$MESSAGES" | jq '. + [{role: "assistant", content: "(empty response)"}]')
        empty_responses=$((empty_responses + 1))
    fi

    # Check format — is it valid JSON?
    format_ok=0
    if echo "$content" | jq '.' >/dev/null 2>&1; then
        format_ok=1
        # Check it has the tool field
        if echo "$content" | jq -e '.tool' >/dev/null 2>&1; then
            format_ok=1
        else
            format_ok=0
            format_errors=$((format_errors + 1))
        fi
    else
        format_errors=$((format_errors + 1))
    fi

    # Check for loops — compare with previous response
    loop_detected=0
    if [ $i -gt 1 ] && [ -n "$content" ]; then
        prev_content=$(echo "$MESSAGES" | jq -r '.[-3].content // ""')
        if [ "$content" = "$prev_content" ]; then
            loop_detected=1
            loops_detected=$((loops_detected + 1))
            log "  ⚠️  LOOP DETECTED — same response as previous round"
        fi
    fi

    # Check for empty/truncated
    if [ "$finish_reason" = "length" ]; then
        log "  ⚠️  Hit token limit (truncated)"
    fi
    if [ ${content_len:-0} -lt 5 ]; then
        log "  ⚠️  Very short response (${content_len:-0} chars) — possible degradation"
    fi

    # Check for crash (curl failed or no response)
    if [ -z "$content" ] && [ "${total_tokens:-0}" -eq 0 ]; then
        crashes=$((crashes + 1))
        log "  ❌ CRASH — no response received"
    fi

    # Accumulate totals
    total_prompt_tokens=$((total_prompt_tokens + prompt_tokens))
    total_completion_tokens=$((total_completion_tokens + completion_tokens))
    total_time_ms=$((total_time_ms + total_ms))

    # Get VRAM after call
    vram_after=$(get_vram)

    # Log round summary
    if [ "$format_ok" -eq 1 ]; then
        log "  ✓ format_ok | ${prompt_tokens}p/${completion_tokens}c tokens | ${total_ms}ms | VRAM: ${vram_before}→${vram_after}MiB"
    else
        log "  ✗ FORMAT ERROR | ${prompt_tokens}p/${completion_tokens}c tokens | ${total_ms}ms | VRAM: ${vram_before}→${vram_after}MiB"
    fi

    # Save CSV row
    echo "$i,$prompt_tokens,$completion_tokens,$total_tokens,${content_len:-0},${prompt_ms:-0},${eval_ms:-0},$total_ms,$finish_reason,$vram_after,$format_ok,$loop_detected" >> "$OUTPUT_DIR/$MODEL/stress_results.csv"

    # Save full conversation every 5 rounds
    if [ $((i % 5)) -eq 0 ]; then
        echo "$MESSAGES" | jq '.' > "$OUTPUT_DIR/$MODEL/conversation_round_${i}.json" 2>/dev/null
        log "  💾 Saved conversation checkpoint (round $i)"
    fi

    # Brief pause to let llama.cpp recover
    sleep 1
done

# ==============================================================================
# Final analysis
# ==============================================================================

log ""
log "=========================================="
log "  STRESS TEST COMPLETE: $MODEL"
log "=========================================="

# Calculate metrics
avg_time_ms=$((total_time_ms / NUM_ROUNDS))
final_vram=$(get_vram)
vram_total=$(get_vram_total)
vram_pct=$((final_vram * 100 / vram_total))

# Parse results for degradation analysis
# Compare first 5 rounds vs last 5 rounds
first5_format=$(head -7 "$OUTPUT_DIR/$MODEL/stress_results.csv" | tail -5 | awk -F, '{sum+=$12}END{printf "%.0f", sum/NR*100}')
last5_format=$(tail -5 "$OUTPUT_DIR/$MODEL/stress_results.csv" | awk -F, '{sum+=$12}END{printf "%.0f", sum/NR*100}')

first5_time=$(head -7 "$OUTPUT_DIR/$MODEL/stress_results.csv" | tail -5 | awk -F, '{sum+=$8}END{printf "%.0f", sum/NR}')
last5_time=$(tail -5 "$OUTPUT_DIR/$MODEL/stress_results.csv" | awk -F, '{sum+=$8}END{printf "%.0f", sum/NR}')

# Prompt processing speed over time
first5_prompt=$(head -7 "$OUTPUT_DIR/$MODEL/stress_results.csv" | tail -5 | awk -F, '{sum+=$7}END{printf "%.0f", sum/NR}')
last5_prompt=$(tail -5 "$OUTPUT_DIR/$MODEL/stress_results.csv" | awk -F, '{sum+=$7}END{printf "%.0f", sum/NR}')

# Format degradation
if [ "$last5_format" -ge "$first5_format" ]; then
    degradation_status="STABLE"
    degradation_score=25
elif [ "$((last5_format + 10))" -ge "$first5_format" ]; then
    degradation_status="MINOR DEGRADATION"
    degradation_score=15
else
    degradation_status="SIGNIFICANT DEGRADATION"
    degradation_score=5
fi

# Speed degradation (prompt processing time increase)
if [ "$first5_prompt" -eq 0 ]; then
    speed_ratio="N/A"
    speed_score=15
elif [ "$last5_prompt" -eq 0 ]; then
    speed_ratio="N/A"
    speed_score=15
else
    speed_ratio=$(echo "scale=1; $last5_prompt / $first5_prompt" | bc 2>/dev/null || echo "N/A")
    speed_val=$(echo "$speed_ratio" | grep -oP '[\d.]+' | head -1)
    if [ -n "$speed_val" ] && [ "$(echo "$speed_val < 2.0" | bc -l)" = "1" ]; then
        speed_score=25
    elif [ "$(echo "$speed_val < 5.0" | bc -l)" = "1" ]; then
        speed_score=15
    else
        speed_score=5
    fi
fi

# Reliability score (25 pts)
format_ok_count=$((NUM_ROUNDS - format_errors))
format_pct=$(echo "scale=0; $format_ok_count * 100 / $NUM_ROUNDS" 2>/dev/null || echo "0")
reliability_score=0
if [ $format_errors -eq 0 ] && [ $empty_responses -eq 0 ] && [ $crashes -eq 0 ]; then
    reliability_score=25
    reliability_status="PERFECT"
elif [ $format_errors -le 2 ] && [ $empty_responses -eq 0 ] && [ $crashes -eq 0 ]; then
    reliability_score=18
    reliability_status="GOOD"
elif [ $format_errors -le 5 ] && [ $crashes -eq 0 ]; then
    reliability_score=10
    reliability_status="DEGRADED"
else
    reliability_score=0
    reliability_status="UNRELIABLE"
fi

# Loop resistance (10 pts)
if [ $loops_detected -eq 0 ]; then
    loop_score=10
elif [ $loops_detected -le 2 ]; then
    loop_score=5
else
    loop_score=0
fi

# VRAM efficiency (15 pts)
if [ "$vram_pct" -lt 85 ]; then
    vram_score=15
elif [ "$vram_pct" -lt 95 ]; then
    vram_score=10
else
    vram_score=5
    reliability_status="$reliability_status + VRAM_PRESSURE"
fi

total_score=$((degradation_score + speed_score + reliability_score + loop_score + vram_score))

log ""
log "  Rounds completed:     $NUM_ROUNDS / $NUM_ROUNDS"
log "  Total prompt tokens:  $total_prompt_tokens"
log "  Total completion:     $total_completion_tokens"
log "  Avg response time:    ${avg_time_ms}ms"
log "  VRAM usage:           ${final_vram}MiB / ${vram_total}MiB (${vram_pct}%)"
log ""
log "  Format errors:        $format_errors / $NUM_ROUNDS"
log "  Empty responses:      $empty_responses"
log "  Loops detected:       $loops_detected"
log "  Crashes:              $crashes"
log ""
log "  First 5 format ok:    ${first5_format}%"
log "  Last 5 format ok:     ${last5_format}%"
log "  Format status:        $degradation_status"
log ""
log "  First 5 avg prompt:   ${first5_prompt}ms"
log "  Last 5 avg prompt:    ${last5_prompt}ms"
log "  Prompt speed ratio:   ${speed_ratio}x (late/early)"
log ""
log "  Reliability:          $reliability_status"
log "=========================================="
log "  STRESS TEST SCORE:    $total_score / 100"
log "=========================================="
log "  Format degradation:   $degradation_score / 25"
log "  Prompt speed:         $speed_score / 25"
log "  Reliability:          $reliability_score / 25"
log "  Loop resistance:      $loop_score / 10"
log "  VRAM efficiency:      $vram_score / 15"
log "=========================================="

# Emit metrics
echo "METRIC stress_total_score=$total_score"
echo "METRIC stress_rounds=$NUM_ROUNDS"
echo "METRIC stress_format_errors=$format_errors"
echo "METRIC stress_empty_responses=$empty_responses"
echo "METRIC stress_loops_detected=$loops_detected"
echo "METRIC stress_crashes=$crashes"
echo "METRIC stress_total_prompt_tokens=$total_prompt_tokens"
echo "METRIC stress_total_completion_tokens=$total_completion_tokens"
echo "METRIC stress_avg_response_ms=$avg_time_ms"
echo "METRIC stress_vram_final=$final_vram"
echo "METRIC stress_vram_pct=$vram_pct"
echo "METRIC stress_first5_format_pct=$first5_format"
echo "METRIC stress_last5_format_pct=$last5_format"
echo "METRIC stress_first5_prompt_ms=$first5_prompt"
echo "METRIC stress_last5_prompt_ms=$last5_prompt"
echo "METRIC stress_prompt_speed_ratio=$speed_ratio"
echo "METRIC stress_degradation=$degradation_status"
echo "METRIC stress_reliability=$reliability_status"

# Save conversation
echo "$MESSAGES" | jq '.' > "$OUTPUT_DIR/$MODEL/final_conversation.json" 2>/dev/null
