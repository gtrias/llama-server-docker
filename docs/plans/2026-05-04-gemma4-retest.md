# Gemma 4 Re-test Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Re-download April 11+ Gemma 4 GGUFs, test tool calling and looping fixes, update config based on results.

**Architecture:** Delete old GGUFs, pull latest Docker image, restart container to auto-download fresh models, then run a structured test matrix against both 26B and 31B variants comparing native template vs custom jinja.

**Tech Stack:** llama.cpp server (Docker), curl for API testing, bash scripts

---

### Task 1: Pull Latest Docker Image

**Files:**
- None modified

**Step 1: Pull the latest llama.cpp server-cuda image**

```bash
docker pull ghcr.io/ggml-org/llama.cpp:server-cuda
```

Expected: Image pulls successfully with a new digest.

**Step 2: Check CUDA version in the new image**

```bash
docker run --rm ghcr.io/ggml-org/llama.cpp:server-cuda nvcc --version 2>/dev/null || \
docker run --rm ghcr.io/ggml-org/llama.cpp:server-cuda cat /usr/local/cuda/version.txt 2>/dev/null || \
echo "Check nvidia-smi inside container"
```

Expected: CUDA version is NOT 13.2 (unsloth warns this causes poor outputs).

**Step 3: Rebuild the custom image**

```bash
cd /home/genar/src/llama-server-docker
docker compose build --no-cache llama-server
```

Expected: Build completes successfully with the new base image.

**Step 4: Commit (no code changes, just note progress)**

No commit needed — infrastructure step only.

---

### Task 2: Delete Old Gemma 4 GGUFs

**Files:**
- Delete: `~/.cache/llama.cpp/gemma-4-26B-A4B-it-UD-Q4_K_M.gguf`
- Delete: `~/.cache/llama.cpp/gemma-4-26B-A4B-it-Q4_K_M.gguf` (older non-UD variant)
- Delete: `~/.cache/llama.cpp/gemma-4-31B-it-Q4_K_M.gguf`
- Delete: `~/.cache/llama.cpp/mmproj-31b-BF16.gguf` (if it exists)

**Step 1: Remove old GGUF files**

```bash
rm -v ~/.cache/llama.cpp/gemma-4-26B-A4B-it-UD-Q4_K_M.gguf
rm -v ~/.cache/llama.cpp/gemma-4-26B-A4B-it-Q4_K_M.gguf
rm -v ~/.cache/llama.cpp/gemma-4-31B-it-Q4_K_M.gguf
rm -vf ~/.cache/llama.cpp/mmproj-31b-BF16.gguf
```

Expected: Files removed. ~35GB freed.

**Step 2: Verify deletion**

```bash
ls ~/.cache/llama.cpp/gemma*
```

Expected: No gemma files found.

---

### Task 3: Prepare Native Template Test Config

**Files:**
- Modify: `config/models.ini` (gemma4-26b and gemma4-31b sections)

**Step 1: Back up current config**

```bash
cp config/models.ini config/models.ini.bak
```

**Step 2: Edit gemma4-26b — comment out custom template**

In `config/models.ini`, comment out the `chat-template-file` line in `[gemma4-26b]`:

```ini
[gemma4-26b]
# Testing native template — custom jinja commented out for comparison
# chat-template-file = /config/gemma4-tool-fix.jinja
```

**Step 3: Edit gemma4-31b — comment out custom template**

Same for `[gemma4-31b]`:

```ini
[gemma4-31b]
# Testing native template — custom jinja commented out for comparison
# chat-template-file = /config/gemma4-tool-fix.jinja
```

**Step 4: Update comment headers**

Replace the old April 8 comment block in `[gemma4-26b]` with:

```ini
[gemma4-26b]
# Unsloth re-quant with imatrix — re-downloaded 2026-05-04 (April 11+ release)
# Includes Google's updated chat template + all llama.cpp Gemma 4 fixes
# Testing native template first (custom jinja kept as fallback)
```

Do NOT commit yet — this is a test config.

---

### Task 4: Restart Container and Auto-Download Fresh GGUFs

**Step 1: Start the container with 26B model to trigger download**

```bash
cd /home/genar/src/llama-server-docker
docker compose up -d llama-server
```

Expected: Container starts, entrypoint detects missing GGUF, downloads from HuggingFace. This will take a while (~15GB for the 26B UD-Q4_K_M).

**Step 2: Monitor download progress**

```bash
docker compose logs -f llama-server
```

Expected: See huggingface-hub download progress, then server starts with the model loaded.

**Step 3: Verify model loaded**

```bash
curl -s http://localhost:11434/v1/models | jq .
```

Expected: Model `gemma4-26b` appears with status "loaded" or similar.

---

### Task 5: Test 26B — Basic Chat (Native Template)

**Step 1: Simple single-turn test**

```bash
curl -s http://localhost:11434/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gemma4-26b",
    "messages": [{"role": "user", "content": "What is the capital of France? Reply in one sentence."}],
    "max_tokens": 100
  }' | jq '.choices[0].message'
```

Expected: Coherent response, no garbled tokens, no `<unused49>` spam.

**Step 2: Multi-turn test**

```bash
curl -s http://localhost:11434/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gemma4-26b",
    "messages": [
      {"role": "user", "content": "Name 3 programming languages."},
      {"role": "assistant", "content": "Python, Rust, and Go."},
      {"role": "user", "content": "Which one is best for web backends? Explain in 2 sentences."}
    ],
    "max_tokens": 200
  }' | jq '.choices[0].message'
```

Expected: Coherent follow-up, no repetition loops.

**Step 3: Record results**

Note in this plan doc or a scratch file: PASS/FAIL + any observations.

---

### Task 6: Test 26B — Tool Calling (Native Template)

**Step 1: Single tool call**

```bash
curl -s http://localhost:11434/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gemma4-26b",
    "messages": [{"role": "user", "content": "What is the weather in San Francisco?"}],
    "tools": [{
      "type": "function",
      "function": {
        "name": "get_weather",
        "description": "Get current weather for a location",
        "parameters": {
          "type": "object",
          "properties": {
            "location": {"type": "string", "description": "City name"},
            "unit": {"type": "string", "enum": ["celsius", "fahrenheit"]}
          },
          "required": ["location"]
        }
      }
    }],
    "max_tokens": 300
  }' | jq '.choices[0].message'
```

Expected: Response contains `tool_calls` array with `get_weather` function, `location` = "San Francisco", valid JSON arguments.

**Step 2: Multi-tool call**

```bash
curl -s http://localhost:11434/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gemma4-26b",
    "messages": [{"role": "user", "content": "What is the weather in Tokyo and also search for flights from SFO to NRT?"}],
    "tools": [
      {
        "type": "function",
        "function": {
          "name": "get_weather",
          "description": "Get current weather for a location",
          "parameters": {
            "type": "object",
            "properties": {
              "location": {"type": "string"}
            },
            "required": ["location"]
          }
        }
      },
      {
        "type": "function",
        "function": {
          "name": "search_flights",
          "description": "Search for flights between airports",
          "parameters": {
            "type": "object",
            "properties": {
              "origin": {"type": "string", "description": "Origin airport code"},
              "destination": {"type": "string", "description": "Destination airport code"}
            },
            "required": ["origin", "destination"]
          }
        }
      }
    ],
    "max_tokens": 500
  }' | jq '.choices[0].message'
```

Expected: Two tool calls in the response — `get_weather` and `search_flights` with correct arguments.

**Step 3: Record results**

Note: PASS/FAIL for single-tool and multi-tool. If FAIL, note the exact error or malformed output.

---

### Task 7: Test 26B — Tool Calling (Custom Jinja Fallback)

Only run this task if Task 6 FAILED.

**Step 1: Re-enable custom template in config**

Uncomment `chat-template-file` in `[gemma4-26b]`:

```ini
chat-template-file = /config/gemma4-tool-fix.jinja
```

**Step 2: Restart container**

```bash
docker compose restart llama-server
```

Wait for model to reload.

**Step 3: Repeat Task 6 tests (single-tool and multi-tool)**

Same curl commands as Task 6.

**Step 4: Record comparison**

Note whether custom jinja fixes the issue that native template couldn't handle.

---

### Task 8: Test 26B — Looping Stress Test

**Step 1: Long multi-turn with tool use**

```bash
curl -s http://localhost:11434/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gemma4-26b",
    "messages": [
      {"role": "user", "content": "Look up the weather in 3 cities: Paris, London, Tokyo"},
      {"role": "assistant", "content": null, "tool_calls": [{"id": "call_1", "type": "function", "function": {"name": "get_weather", "arguments": "{\"location\": \"Paris\"}"}}]},
      {"role": "tool", "tool_call_id": "call_1", "content": "{\"temp\": 18, \"condition\": \"cloudy\"}"},
      {"role": "user", "content": "Great, now summarize all three cities weather and recommend which to visit."}
    ],
    "tools": [{
      "type": "function",
      "function": {
        "name": "get_weather",
        "description": "Get current weather",
        "parameters": {
          "type": "object",
          "properties": {"location": {"type": "string"}},
          "required": ["location"]
        }
      }
    }],
    "max_tokens": 500
  }' | jq '.choices[0].message'
```

Expected: Model either makes additional tool calls for London/Tokyo OR summarizes based on available info. No infinite repetition, no `<unused49>` tokens.

**Step 2: Open-ended generation (repetition check)**

```bash
curl -s http://localhost:11434/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gemma4-26b",
    "messages": [{"role": "user", "content": "Write a detailed 500-word essay about the history of coffee."}],
    "max_tokens": 1000
  }' | jq '.choices[0].message.content' | head -c 2000
```

Expected: Coherent essay, no sentence-level repetition loops.

---

### Task 9: Test 31B Dense

**Step 1: Switch to 31B model**

Load the 31B model via the API (router mode swaps models):

```bash
curl -s http://localhost:11434/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gemma4-31b",
    "messages": [{"role": "user", "content": "Hello, respond in one sentence."}],
    "max_tokens": 50
  }' | jq '.choices[0].message'
```

Expected: Model loads (may take a minute for download + load), responds coherently. Watch `docker compose logs` for any OOM errors.

**Step 2: Check VRAM usage**

```bash
nvidia-smi --query-gpu=memory.used,memory.total --format=csv
```

Expected: Under 24GB. If at or near 24GB, note that context will be severely limited.

**Step 3: Run same tool calling test as Task 6 Step 1 but with model "gemma4-31b"**

**Step 4: Run same looping test as Task 8 Step 2 but with model "gemma4-31b"**

**Step 5: Record results and VRAM usage**

Decision point: if 31B OOMs or leaves <2GB headroom, recommend dropping it from config.

---

### Task 10: Test Thinking Mode (Optional)

**Step 1: Test with thinking enabled on 26B**

```bash
curl -s http://localhost:11434/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gemma4-26b",
    "messages": [
      {"role": "user", "content": "If a train leaves at 3pm going 60mph and another at 4pm going 90mph, when does the second catch up?"}
    ],
    "chat_template_kwargs": {"enable_thinking": true},
    "max_tokens": 1000
  }' | jq '.choices[0].message'
```

Expected: Response may include thinking tokens or just a better-reasoned answer.

Note: If `chat_template_kwargs` isn't supported via API, this may need to be set in `models.ini` instead. Skip if not straightforward.

---

### Task 11: Finalize Config and Commit

**Files:**
- Modify: `config/models.ini`
- Possibly delete: `config/gemma4-tool-fix.jinja` (if native template works)
- Delete: `config/models.ini.bak`

**Step 1: Update models.ini based on test results**

If native template passed all tests:
- Remove `chat-template-file` lines from both gemma4 sections
- Update comments to reflect April 11+ GGUFs and native template

If native template failed, custom jinja still needed:
- Uncomment `chat-template-file` lines
- Update comments to note which specific issue persists

If 31B doesn't fit:
- Remove the entire `[gemma4-31b]` section

**Step 2: Clean up**

```bash
rm config/models.ini.bak
```

If native template works and custom jinja is no longer needed:
```bash
rm config/gemma4-tool-fix.jinja
```

**Step 3: Commit**

```bash
git add config/models.ini
git add -u config/  # picks up deleted files
git commit -m "feat: update Gemma 4 to April 11 GGUFs, test results: [native/custom] template"
```

Adjust commit message based on actual results.
