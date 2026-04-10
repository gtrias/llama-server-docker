#!/bin/bash
set -euo pipefail

# ==============================================================================
# HTTP Server Challenge: Can the model build a working server from scratch?
# ==============================================================================

BASE_URL="${LLAMA_BASE_URL:-http://localhost:11434/v1}"
MODEL="${1:?Usage: $0 <model-alias> [output-dir]}"
OUTPUT_DIR="${2:-/tmp/http-challenge}"
TEST_PORT="${TEST_PORT:-8192}"

mkdir -p "$OUTPUT_DIR"

log() { echo "[http] $1" >&2; }

PROMPT_FILE="/tmp/http-challenge-prompt.txt"
cat > "$PROMPT_FILE" << 'PROMPT_EOF'
Create a complete HTTP server from scratch in a single Python file. No frameworks, no libraries — only Python standard library (socket, threading, json, os, datetime, etc).

Requirements:
- Listen on port 8192
- Parse raw HTTP requests (method, path, headers, body) manually using socket
- Serve these endpoints:

  GET /status
    → 200 JSON: {"status":"ok","uptime_seconds":<int>,"requests_count":<int>}

  GET /tasks
    → 200 JSON: {"tasks":[...]}

  POST /tasks
    → Body: {"title":"<string>","priority":"<low|medium|high>"}
    → Validate: title is required, priority must be one of low/medium/high
    → 201 JSON: {"id":<int>,"title":"...","priority":"...","created_at":"<ISO8601>"}
    → 400 JSON: {"error":"..."} on validation failure

  PUT /tasks/<id>
    → Body: same as POST, partial updates allowed
    → 200 JSON: updated task
    → 404 JSON: {"error":"Task not found"} if id doesn't exist

  DELETE /tasks/<id>
    → 204 no body on success
    → 404 JSON: {"error":"Task not found"} if id doesn't exist

  GET /tasks/<id>
    → 200 JSON: task object
    → 404 JSON: {"error":"Task not found"} if id doesn't exist

- Include CORS headers on all responses (Access-Control-Allow-Origin: *, Access-Control-Allow-Methods: *, Access-Control-Allow-Headers: *)
- Handle OPTIONS preflight requests (204 no body)
- Threaded: handle multiple concurrent requests (one thread per connection)
- Proper Content-Type headers (application/json for JSON responses)
- All responses must include Content-Length header
- Log each request to stdout: METHOD /path STATUS (one line per request)
- The server must start when run: python server.py
- Include at least 3 seed tasks on startup so GET /tasks returns data immediately

Output ONLY the complete Python file. No explanation, no markdown, just the code starting with #! or import.
PROMPT_EOF

PROMPT=$(cat "$PROMPT_FILE")

log "Sending HTTP server challenge to $MODEL..."

start_time=$(date +%s%3N)

RESPONSE_JSON="/tmp/http-response-${MODEL}.json"
curl -s --max-time 300 "$BASE_URL/chat/completions" \
    -H "Content-Type: application/json" \
    -d "$(jq -n \
        --arg model "$MODEL" \
        --arg prompt "$PROMPT" \
        --argjson max_tokens 16384 \
        '{
            model: $model,
            messages: [
                {role: "system", content: "You are an expert backend engineer. Output only code, no explanation. Produce complete, working, copy-pasteable code."},
                {role: "user", content: $prompt}
            ],
            max_tokens: $max_tokens,
            temperature: 0.3,
            stream: false
        }')" > "$RESPONSE_JSON" 2>&1

end_time=$(date +%s%3N)
total_ms=$((end_time - start_time))

content=$(jq -r '.choices[0].message.content // ""' "$RESPONSE_JSON" 2>/dev/null)
if [ -z "$content" ]; then
    content=$(jq -r '.choices[0].message.reasoning_content // ""' "$RESPONSE_JSON" 2>/dev/null)
fi

prompt_tokens=$(jq -r '.usage.prompt_tokens // 0' "$RESPONSE_JSON" 2>/dev/null)
completion_tokens=$(jq -r '.usage.completion_tokens // 0' "$RESPONSE_JSON" 2>/dev/null)

if [ -z "$content" ]; then
    log "ERROR: No response from model"
    echo "METRIC http_code_score=0"
    echo "METRIC http_live_score=0"
    echo "METRIC http_gen_ms=$total_ms"
    exit 1
fi

# Extract Python code — strip markdown fences
py_content=$(echo "$content" | sed 's/^```python//' | sed 's/^```//' | sed 's/```$//')

if ! echo "$py_content" | head -5 | grep -qiE "^#!|import|def|class|from"; then
    py_content=$(echo "$content" | sed -n '/^import\|^#!/,/^$/p' 2>/dev/null)
fi

if [ -z "$py_content" ] || [ ${#py_content} -lt 500 ]; then
    log "ERROR: No valid Python extracted (${#py_content} bytes)"
    echo "METRIC http_code_score=0"
    echo "METRIC http_live_score=0"
    echo "METRIC http_gen_ms=$total_ms"
    exit 1
fi

output_file="$OUTPUT_DIR/$MODEL/server.py"
mkdir -p "$OUTPUT_DIR/$MODEL"
printf '%s' "$py_content" > "$output_file"
file_bytes=$(wc -c < "$output_file")

log "Generated $output_file ($file_bytes bytes, $((total_ms/1000))s)"

# ==============================================================================
# Static code analysis (10 points)
# ==============================================================================

score=0

has_pattern() {
    echo "$py_content" | grep -qiE "$1" 2>/dev/null
}

log ""
log "Code analysis:"

if has_pattern "import socket";     then score=$((score+1)); log "  [PASS] Socket usage (+1)";       else log "  [FAIL] Socket usage"; fi
if has_pattern "import threading|thread"; then score=$((score+1)); log "  [PASS] Threading (+1)";     else log "  [FAIL] Threading"; fi
if has_pattern "import json";       then score=$((score+1)); log "  [PASS] JSON handling (+1)";      else log "  [FAIL] JSON handling"; fi
if has_pattern "def.*handle|def.*request|def.*parse"; then score=$((score+1)); log "  [PASS] Request handler (+1)"; else log "  [FAIL] Request handler"; fi
if has_pattern "HTTP/1";            then score=$((score+1)); log "  [PASS] HTTP response format (+1)"; else log "  [FAIL] HTTP response format"; fi
if has_pattern "Content-Type|content-type"; then score=$((score+1)); log "  [PASS] Content-Type (+1)"; else log "  [FAIL] Content-Type"; fi
if has_pattern "Content-Length|content-length"; then score=$((score+1)); log "  [PASS] Content-Length (+1)"; else log "  [FAIL] Content-Length"; fi
if has_pattern "Access-Control|cors"; then score=$((score+1)); log "  [PASS] CORS (+1)";             else log "  [FAIL] CORS"; fi
if has_pattern "404|Not Found|not_found"; then score=$((score+1)); log "  [PASS] Error handling (+1)"; else log "  [FAIL] Error handling"; fi
if has_pattern "8192";              then score=$((score+1)); log "  [PASS] Correct port (+1)";       else log "  [FAIL] Correct port"; fi

log ""
log "Code score: $score / 10"

# ==============================================================================
# Live server tests (20 points) — start server, curl endpoints, score results
# ==============================================================================

log ""
log "Starting server on port $TEST_PORT..."

# Kill any leftover server
pkill -f "python3? $output_file" 2>/dev/null || true
sleep 1

# Start server in background, capture output
SERVER_LOG="$OUTPUT_DIR/$MODEL/server.log"
python3 "$output_file" > "$SERVER_LOG" 2>&1 &
SERVER_PID=$!

# Wait for server to be ready
log "Waiting for server (PID $SERVER_PID)..."
ready=false
for i in $(seq 1 15); do
    if curl -s --max-time 1 "http://localhost:$TEST_PORT/status" >/dev/null 2>&1; then
        ready=true
        break
    fi
    sleep 1
done

if ! $ready; then
    log "ERROR: Server did not start"
    kill $SERVER_PID 2>/dev/null || true
    wait $SERVER_PID 2>/dev/null || true
    echo "METRIC http_code_score=$score"
    echo "METRIC http_live_score=0"
    echo "METRIC http_gen_ms=$total_ms"
    echo "METRIC http_gen_s=$((total_ms / 1000))"
    echo "METRIC http_file_bytes=$file_bytes"
    echo "METRIC http_completion_tokens=$completion_tokens"
    echo "METRIC http_server_started=0"
    exit 1
fi

log "Server is running"

live_score=0
test_log=""

run_test() {
    local name="$1" method="$2" path="$3" data="$4"
    local expected_status="$5" check="$6" points="$7"

    local response status_code body http_code
    if [ "$method" = "GET" ]; then
        response=$(curl -s -w "\n%{http_code}" --max-time 5 "http://localhost:$TEST_PORT$path")
    elif [ "$method" = "POST" ] || [ "$method" = "PUT" ]; then
        response=$(curl -s -w "\n%{http_code}" --max-time 5 -X "$method" \
            -H "Content-Type: application/json" \
            -d "$data" \
            "http://localhost:$TEST_PORT$path")
    elif [ "$method" = "DELETE" ]; then
        response=$(curl -s -w "\n%{http_code}" --max-time 5 -X DELETE "http://localhost:$TEST_PORT$path")
    elif [ "$method" = "OPTIONS" ]; then
        response=$(curl -s -w "\n%{http_code}" --max-time 5 -X OPTIONS \
            -H "Origin: http://example.com" \
            "http://localhost:$TEST_PORT$path")
    fi

    http_code=$(echo "$response" | tail -1)
    body=$(echo "$response" | sed '$d')

    local pass=false
    if [ "$http_code" = "$expected_status" ]; then
        if [ -n "$check" ]; then
            if echo "$body" | grep -qiE "$check"; then
                pass=true
            fi
        else
            pass=true
        fi
    fi

    if $pass; then
        live_score=$((live_score + points))
        log "  [PASS] $name (+$points) — HTTP $http_code"
    else
        log "  [FAIL] $name (0/$points) — expected $expected_status, got $http_code"
        if [ -n "$body" ]; then
            log "         Body: $(echo "$body" | head -c 120)"
        fi
    fi
}

log ""
log "Live tests:"

# Seed tasks check (2 pts)
run_test "GET /status returns JSON" GET "/status" "" "200" "status.*ok|uptime|requests" 2

# List tasks (2 pts)
run_test "GET /tasks returns array" GET "/tasks" "" "200" "tasks.*\[|\"id\"|\"title\"" 2

# Create task valid (3 pts)
CREATE_RESP=$(curl -s -w "\n%{http_code}" --max-time 5 -X POST \
    -H "Content-Type: application/json" \
    -d '{"title":"Test HTTP challenge","priority":"high"}' \
    "http://localhost:$TEST_PORT/tasks")
CREATE_CODE=$(echo "$CREATE_RESP" | tail -1)
CREATE_BODY=$(echo "$CREATE_RESP" | sed '$d')
TASK_ID=$(echo "$CREATE_BODY" | grep -oP '"id"\s*:\s*\K\d+' | head -1)

if [ "$CREATE_CODE" = "201" ]; then
    live_score=$((live_score + 3))
    log "  [PASS] POST /tasks valid (+3) — HTTP 201"
else
    log "  [FAIL] POST /tasks valid (0/3) — expected 201, got $CREATE_CODE"
    log "         Body: $(echo "$CREATE_BODY" | head -c 200)"
fi

# Create task validation (2 pts)
run_test "POST /tasks missing title → 400" POST "/tasks" '{"priority":"low"}' "400" "error|title|required" 2

# Create task invalid priority (1 pt)
run_test "POST /tasks bad priority → 400" POST "/tasks" '{"title":"x","priority":"urgent"}' "400" "error|priority" 1

# Get single task (2 pts)
if [ -n "$TASK_ID" ]; then
    run_test "GET /tasks/$TASK_ID returns task" GET "/tasks/$TASK_ID" "" "200" "title.*Test HTTP|\"id\".*$TASK_ID" 2

    # Update task (3 pts)
    run_test "PUT /tasks/$TASK_ID updates" PUT "/tasks/$TASK_ID" '{"title":"Updated task"}' "200" "Updated task|title.*updated" 3

    # Delete task (2 pts)
    run_test "DELETE /tasks/$TASK_ID → 204" DELETE "/tasks/$TASK_ID" "" "204" "" 2

    # Get deleted task (1 pt)
    run_test "GET /tasks/$TASK_ID → 404" GET "/tasks/$TASK_ID" "" "404" "not.found|error" 1

    # Delete non-existent (1 pt)
    run_test "DELETE /tasks/99999 → 404" DELETE "/tasks/99999" "" "404" "not.found|error" 1
else
    log "  [SKIP] Single task tests (no task ID from POST)"
fi

# CORS preflight (1 pt)
run_test "OPTIONS preflight → 204" OPTIONS "/tasks" "" "204" "" 1

log ""
log "Live score: $live_score / 20"

# Check server log for request logging
if grep -q "GET\|POST\|PUT\|DELETE" "$SERVER_LOG" 2>/dev/null; then
    log "  [PASS] Request logging detected"
    live_score=$((live_score + 1))
else
    log "  [FAIL] No request logging detected"
fi

# Kill server
kill $SERVER_PID 2>/dev/null || true
wait $SERVER_PID 2>/dev/null || true

total=$((score + live_score))

log ""
log "=== FINAL SCORE: $total / 30 (code: $score, live: $live_score) ==="

# Emit all metrics
echo "METRIC http_total_score=$total"
echo "METRIC http_code_score=$score"
echo "METRIC http_live_score=$live_score"
echo "METRIC http_gen_ms=$total_ms"
echo "METRIC http_gen_s=$((total_ms / 1000))"
echo "METRIC http_file_bytes=$file_bytes"
echo "METRIC http_completion_tokens=$completion_tokens"
echo "METRIC http_prompt_tokens=$prompt_tokens"
echo "METRIC http_server_started=1"

log ""
log "Server file: $output_file"
log "Server log:  $SERVER_LOG"
