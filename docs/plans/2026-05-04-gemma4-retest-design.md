# Gemma 4 Re-test Design

## Context

Gemma 4 was initially set up in early April 2026 (April 8 unsloth quants). Two issues were experienced:
- **Tool calling failures** — the peg-gemma4 parser had array serialization bugs, requiring a custom `gemma4-tool-fix.jinja` workaround
- **Looping/repetition** — model entering infinite repetition loops, especially the 26B MoE variant

On April 11, unsloth re-released all Gemma 4 GGUFs with Google's updated official chat template and llama.cpp fixes baked in. These fixes specifically target tool calling and stability. Our current GGUFs predate this update.

## Approach

Fresh download of April 11+ GGUFs, test whether native template resolves both issues, update config accordingly.

## Re-download Strategy

**Models to re-download:**
- `gemma-4-26B-A4B-it-UD-Q4_K_M.gguf` from `unsloth/gemma-4-26B-A4B-it-GGUF`
- `gemma-4-31B-it-Q4_K_M.gguf` from `unsloth/gemma-4-31B-it-GGUF`
- `mmproj-31b-BF16.gguf` (vision projector for 31B)

**Keep:** Custom `gemma4-tool-fix.jinja` for comparison testing.

**Docker image:** Pull latest `ghcr.io/ggml-org/llama.cpp:server-cuda`. Verify NOT built with CUDA 13.2 (causes poor outputs per unsloth docs).

**Method:** Delete existing GGUFs from `~/.cache/llama.cpp/`, let auto-download entrypoint fetch fresh on container restart.

## Test Plan

Run each test against both 26B and 31B:

1. **Basic chat** — multi-turn conversation, check for coherent output, no garbled tokens
2. **Tool calling with native template** — remove `chat-template-file` from models.ini, test single-tool, multi-tool, nested arguments
3. **Tool calling with custom jinja** — re-enable `gemma4-tool-fix.jinja`, repeat same tests
4. **Looping stress test** — longer conversations, multi-turn tool use, check for infinite repetition or `<unused49>` token spam
5. **Thinking mode** — test with `enable_thinking=true`

**Test method:** Hit `/v1/chat/completions` endpoint with tool definitions via curl or script.

**Success criteria:**
- Tool calls return valid JSON with correct function names and arguments
- No infinite looping or unused token spam
- 26B: sustained ~20+ tok/s
- 31B: fits in VRAM at Q4_K_M without OOM at 8-16K context

## Config Updates (Post-Test)

- Update comment headers to note April 11 re-download
- Add or remove `chat-template-file` based on native template test results
- If thinking mode works, consider adding `chat-template-kwargs`
- If 31B doesn't fit on 24GB VRAM, remove `[gemma4-31b]` section

## Key References

- Unsloth April 11 announcement: https://www.reddit.com/r/unsloth/comments/1t3czdu/gemma_4_updated_ggufs_and_chat_template/
- HF 26B: https://huggingface.co/unsloth/gemma-4-26B-A4B-it-GGUF
- HF 31B: https://huggingface.co/unsloth/gemma-4-31B-it-GGUF
- Unsloth docs: https://unsloth.ai/docs/models/gemma-4
- CUDA 13.2 warning: https://unsloth.ai/docs/models/gemma-4
