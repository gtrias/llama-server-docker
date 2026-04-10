#!/bin/bash
set -euo pipefail

# ==============================================================================
# Agent Tool-Calling Challenge: Can the model fix bugs like Pi does every day?
# 
# Creates a bugged Python project, gives the model tools (read, write, bash),
# and scores it on: bugs fixed, tests passing, efficiency, verification.
# ==============================================================================

BASE_URL="${LLAMA_BASE_URL:-http://localhost:11434/v1}"
MODEL="${1:?Usage: $0 <model-alias> [output-dir]}"
OUTPUT_DIR="${2:-/tmp/agent-challenge}"
MAX_ROUNDS="${MAX_ROUNDS:-15}"

mkdir -p "$OUTPUT_DIR"

log() { echo "[agent] $1" >&2; }

PROJECT_DIR="$OUTPUT_DIR/$MODEL/project"
LOG_FILE="$OUTPUT_DIR/$MODEL/agent_log.jsonl"

# ==============================================================================
# 1. Scaffold the bugged project
# ==============================================================================
log "Scaffolding bugged project at $PROJECT_DIR..."
python3 scripts/benchmark/agent-scaffold.py "$PROJECT_DIR" 2>&1
cp scripts/benchmark/agent-scaffold.py "$OUTPUT_DIR/$MODEL/"

# Run the tests first to confirm they fail
log "Running baseline tests..."
cd "$PROJECT_DIR"
BASELINE_RESULT=$(python3 test_app.py 2>&1 || true)
BASELINE_PASSED=$(echo "$BASELINE_RESULT" | grep -oP '\d+ passed' | grep -oP '\d+' || echo 0)
BASELINE_FAILED=$(echo "$BASELINE_RESULT" | grep -oP '\d+ failed' | grep -oP '\d+' || echo 8)
log "Baseline: ${BASELINE_PASSED} passed, ${BASELINE_FAILED} failed"

cd - >/dev/null

# ==============================================================================
# 2. Run the agent loop
# ==============================================================================

mkdir -p "$OUTPUT_DIR/$MODEL"

SYSTEM_PROMPT='You are a debugging agent. A Python project has bugs causing tests to fail. Your job:

1. First, run the tests: use the bash tool with "cd /PROJECT_DIR && python3 test_app.py"
2. Read the failing test file to understand what is expected
3. Read the source files to find the bugs
4. Fix the bugs by writing corrected files
5. Re-run the tests to verify your fixes
6. Repeat until ALL tests pass

Available tools:
- read_file: reads a file and returns its contents
- write_file: writes content to a file (full replacement)
- bash: runs a shell command and returns stdout+stderr

Be efficient. Read only the files you need. Make targeted fixes. Always verify with tests.

IMPORTANT: 
- When you fix a file, you must write the COMPLETE file contents, not just the changed lines
- The project is at: /PROJECT_DIR
- You have a limited number of rounds, so prioritize the most impactful fixes first'

SYSTEM_PROMPT="${SYSTEM_PROMPT//\/PROJECT_DIR/$PROJECT_DIR}"

USER_PROMPT="The test suite at $PROJECT_DIR/test_app.py has failing tests. Fix all bugs in the project so that all tests pass. Start by running the tests to see what fails."

log "Starting agent loop with $MODEL (max $MAX_ROUNDS rounds)..."

# Build the initial messages
MESSAGES_JSON=$(jq -n \
    --arg system "$SYSTEM_PROMPT" \
    --arg user "$USER_PROMPT" \
    '[
        {role: "system", content: $system},
        {role: "user", content: $user}
    ]')

TOOL_DEFS='[
    {
        "type": "function",
        "function": {
            "name": "read_file",
            "description": "Read the contents of a file. Returns the full file content.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "Absolute file path to read"}
                },
                "required": ["path"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "write_file",
            "description": "Write content to a file. Replaces the entire file. Use for fixing source files.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "Absolute file path to write"},
                    "content": {"type": "string", "description": "Complete file contents to write"}
                },
                "required": ["path", "content"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "bash",
            "description": "Run a shell command and return stdout and stderr. Use for running tests, checking output, etc.",
            "parameters": {
                "type": "object",
                "properties": {
                    "command": {"type": "string", "description": "Shell command to execute"}
                },
                "required": ["command"]
            }
        }
    }
]'

total_tool_calls=0
total_tokens=0
all_tests_pass=false
round=0

while [ $round -lt $MAX_ROUNDS ]; do
    round=$((round + 1))
    log "--- Round $round ---"

    # Call the model
    RESPONSE_JSON=$(mktemp)
    curl -s --max-time 120 "$BASE_URL/chat/completions" \
        -H "Content-Type: application/json" \
        -d "$(jq -n \
            --arg model "$MODEL" \
            --argjson messages "$MESSAGES_JSON" \
            --argjson tools "$TOOL_DEFS" \
            --argjson max_tokens 4096 \
            '{
                model: $model,
                messages: $messages,
                tools: $tools,
                max_tokens: $max_tokens,
                temperature: 0.2,
                tool_choice: "auto"
            }')" > "$RESPONSE_JSON" 2>&1

    # Extract usage
    round_tokens=$(jq -r '.usage.total_tokens // 0' "$RESPONSE_JSON" 2>/dev/null)
    total_tokens=$((total_tokens + round_tokens))

    # Check for errors
    finish_reason=$(jq -r '.choices[0].finish_reason // ""' "$RESPONSE_JSON" 2>/dev/null)
    if [ "$finish_reason" = "length" ]; then
        log "WARNING: Model hit token limit, continuing with partial response"
    fi

    # Get the assistant message
    ASSISTANT_MSG=$(jq '.choices[0].message' "$RESPONSE_JSON" 2>/dev/null)

    # Log the round
    echo "$ASSISTANT_MSG" | jq -c --arg round "$round" --arg tokens "$round_tokens" '{round: ($round|tonumber), tokens: ($tokens|tonumber)}' >> "$LOG_FILE"

    # Check for tool calls
    has_tools=$(echo "$ASSISTANT_MSG" | jq '.tool_calls != null')

    if [ "$has_tools" != "true" ]; then
        # No tool calls — model is done (or stuck)
        final_content=$(echo "$ASSISTANT_MSG" | jq -r '.content // "empty"')
        log "Model finished (no tool calls): $(echo "$final_content" | head -c 200)"
        break
    fi

    # Process tool calls
    num_tool_calls=$(echo "$ASSISTANT_MSG" | jq '.tool_calls | length')
    log "Model made $num_tool_calls tool call(s)"

    # Add assistant message to conversation
    MESSAGES_JSON=$(echo "$MESSAGES_JSON" | jq --argjson msg "$ASSISTANT_MSG" '. + [$msg]')

    # Execute each tool call
    for tc_idx in $(seq 0 $((num_tool_calls - 1))); do
        tool_name=$(echo "$ASSISTANT_MSG" | jq -r ".tool_calls[$tc_idx].function.name")
        tool_args=$(echo "$ASSISTANT_MSG" | jq -r ".tool_calls[$tc_idx].function.arguments")
        tool_call_id=$(echo "$ASSISTANT_MSG" | jq -r ".tool_calls[$tc_idx].id")

        total_tool_calls=$((total_tool_calls + 1))

        log "  Tool: $tool_name"

        case "$tool_name" in
            read_file)
                file_path=$(echo "$tool_args" | jq -r '.path')
                if [ -f "$file_path" ]; then
                    file_content=$(cat "$file_path")
                    tool_result="File: $file_path\n$(wc -l < "$file_path") lines\n---\n$file_content"
                    log "    Read: $file_path ($(wc -l < "$file_path") lines)"
                else
                    tool_result="Error: File not found: $file_path"
                    log "    ERROR: File not found: $file_path"
                fi
                ;;
            write_file)
                file_path=$(echo "$tool_args" | jq -r '.path')
                file_content=$(echo "$tool_args" | jq -r '.content')
                mkdir -p "$(dirname "$file_path")"
                printf '%s' "$file_content" > "$file_path"
                bytes_written=$(wc -c < "$file_path")
                tool_result="Written $bytes_written bytes to $file_path"
                log "    Wrote: $file_path ($bytes_written bytes)"
                ;;
            bash)
                cmd=$(echo "$tool_args" | jq -r '.command')
                # Execute with timeout, capture output
                bash_output=$(cd "$PROJECT_DIR" && timeout 30 bash -c "$cmd" 2>&1) || true
                tool_result="$bash_output"
                log "    Bash: $(echo "$cmd" | head -c 100)"
                # Check if tests pass
                if echo "$cmd" | grep -q "test_app.py"; then
                    if echo "$bash_output" | grep -q "0 failed"; then
                        all_tests_pass=true
                        log "    *** ALL TESTS PASS! ***"
                    fi
                    log "    Result: $(echo "$bash_output" | tail -3)"
                fi
                ;;
            *)
                tool_result="Error: Unknown tool: $tool_name"
                log "    ERROR: Unknown tool: $tool_name"
                ;;
        esac

        # Add tool result to conversation (truncated to 4000 chars to save context)
        truncated=$(echo -e "$tool_result" | head -c 4000)
        MESSAGES_JSON=$(echo "$MESSAGES_JSON" | jq \
            --arg tool_call_id "$tool_call_id" \
            --arg content "$truncated" \
            '. + [{"role": "tool", "tool_call_id": $tool_call_id, "content": $content}]')

        # Log tool result
        echo "{\"round\":$round,\"tool\":\"$tool_name\",\"result_len\":${#truncated}}" >> "$LOG_FILE"
    done

    # If tests pass, we can stop after this round
    if $all_tests_pass; then
        log "*** ALL TESTS PASS after $round rounds ***"
        break
    fi
done

# ==============================================================================
# 3. Final test run and scoring
# ==============================================================================
log ""
log "Running final tests..."
cd "$PROJECT_DIR"
FINAL_RESULT=$(python3 test_app.py 2>&1 || true)
FINAL_EXIT=$?
cd - >/dev/null

final_passed=$(echo "$FINAL_RESULT" | grep -oP '\d+ passed' | grep -oP '\d+' || echo 0)
final_failed=$(echo "$FINAL_RESULT" | grep -oP '\d+ failed' | grep -oP '\d+' || echo 8)

log "Final: $final_passed passed, $final_failed failed"

# Save results
echo "$FINAL_RESULT" > "$OUTPUT_DIR/$MODEL/test_results.txt"
echo "$MESSAGES_JSON" | jq '.' > "$OUTPUT_DIR/$MODEL/conversation.json" 2>/dev/null

# ==============================================================================
# 4. Scoring
# ==============================================================================

# Tests passed (40 pts — 5 pts per test)
test_score=$((final_passed * 5))
log "Test score: $test_score / 40"

# Efficiency: fewer tool calls = better (20 pts max)
if [ $total_tool_calls -le 8 ]; then
    efficiency_score=20
elif [ $total_tool_calls -le 12 ]; then
    efficiency_score=15
elif [ $total_tool_calls -le 15 ]; then
    efficiency_score=10
else
    efficiency_score=5
fi
log "Efficiency score: $efficiency_score / 20 ($total_tool_calls tool calls in $round rounds)"

# Verification: did the model run tests after fixing? (20 pts)
test_runs=0
ran_tests_after_fix=false
if grep -q '"bash"' "$LOG_FILE" 2>/dev/null; then
    test_runs=$(grep -c '"bash"' "$LOG_FILE" 2>/dev/null || true)
    test_runs=${test_runs:-0}
    if [ "$test_runs" -ge 2 ]; then
        verification_score=20
        ran_tests_after_fix=true
    elif [ "$test_runs" -ge 1 ]; then
        verification_score=10
    else
        verification_score=0
    fi
else
    verification_score=0
fi
log "Verification score: $verification_score / 20 (ran tests $test_runs times)"

# Strategy: did it run tests first? (10 pts)
read_tests_first=false
if head -5 "$LOG_FILE" 2>/dev/null | grep -q '"bash"'; then
    strategy_score=10
    read_tests_first=true
    log "Strategy score: 10 / 10 (ran tests first)"
else
    strategy_score=0
    log "Strategy score: 0 / 10 (did not run tests first)"
fi

# Completeness: did it fix all 3 source files? (10 pts)
files_modified=0
conv_file="$OUTPUT_DIR/$MODEL/conversation.json"
if [ -f "$conv_file" ]; then
    for src_file in app.py parser.py formatter.py; do
        if grep -q "$src_file" "$conv_file" 2>/dev/null; then
            files_modified=$((files_modified + 1))
        fi
    done
fi
if [ "$files_modified" -ge 3 ]; then
    completeness_score=10
elif [ "$files_modified" -ge 2 ]; then
    completeness_score=7
elif [ "$files_modified" -ge 1 ]; then
    completeness_score=3
else
    completeness_score=0
fi
log "Completeness score: $completeness_score / 10 (modified $files_modified source files)"

total_score=$((test_score + efficiency_score + verification_score + strategy_score + completeness_score))

log ""
log "=========================================="
log "  AGENT CHALLENGE SCORE: $total_score / 100"
log "=========================================="
log "  Tests:        $test_score / 40  ($final_passed/8 passing)"
log "  Efficiency:   $efficiency_score / 20  ($total_tool_calls tool calls, $round rounds)"
log "  Verification: $verification_score / 20  (ran tests $test_runs times)"
log "  Strategy:     $strategy_score / 10  (read tests first: $read_tests_first)"
log "  Completeness: $completeness_score / 10  ($files_modified files modified)"
log "=========================================="
log "  Total tokens: $total_tokens"
log "=========================================="

# Emit metrics
echo "METRIC agent_total_score=$total_score"
echo "METRIC agent_tests_passed=$final_passed"
echo "METRIC agent_tests_failed=$final_failed"
echo "METRIC agent_test_score=$test_score"
echo "METRIC agent_efficiency_score=$efficiency_score"
echo "METRIC agent_verification_score=$verification_score"
echo "METRIC agent_strategy_score=$strategy_score"
echo "METRIC agent_completeness_score=$completeness_score"
echo "METRIC agent_tool_calls=$total_tool_calls"
echo "METRIC agent_rounds=$round"
echo "METRIC agent_total_tokens=$total_tokens"
echo "METRIC agent_all_pass=$( $all_tests_pass && echo 1 || echo 0 )"

log ""
log "Files: $OUTPUT_DIR/$MODEL/"
