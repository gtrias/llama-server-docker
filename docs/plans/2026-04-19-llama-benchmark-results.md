# Llama Benchmark Results

**Date**: 2026-04-20
**Model**: Qwen3.6-35B-A3B-APEX-I-Compact (17GB)
**GPU**: RTX 3090 (24GB)
**Server**: llama.cpp v8720, Docker, port 11434
**Config**: ctx-size 131072, flash-attn on, cache-type-k q8_0, cache-type-v q8_0

## Model Benchmark

| Context (tokens) | Time (ms) | Gen tok/s | VRAM (MB) | Cached | Status |
|------------------|-----------|-----------|-----------|--------|--------|
| ~500             | 2,391     | 36.3      | 19,760    | 0      | ✅ OK  |
| ~5K (30 calls)   | 1,500     | 95-100    | 19,760    | 0      | ✅ OK  |
| ~80K             | 40,029    | ~25       | 19,760    | 0      | ✅ OK  |
| ~120K            | 27,526    | ~25       | 19,812    | 79,504 | ✅ OK  |

## Session Benchmark (30 sequential calls)

- **Calls completed**: 30/30 ✅
- **Final context**: 5,279 tokens
- **Tok/s**: Stable 93-100 throughout (small context)
- **VRAM**: Rock-solid at 19,760 MB
- **No errors, no timeouts, no OOM**

## Key Findings

### 1. Model is NOT the problem
The model handles context from 500 to 120K tokens without any errors, OOM, or crashes. VRAM stays stable at ~19.8GB regardless of context size. The KV cache with q8_0 is very efficient.

### 2. Performance at scale
- **Small context (<10K)**: 90-100 tok/s — excellent
- **Large context (80K+)**: ~25 tok/s generation, but prefill dominates (40s for 80K prompt)
- **Caching works**: 120K context with 79K cached tokens completes faster (27s) than uncached 80K (40s)

### 3. The real problem is PI agent framework, not the model
The user reports that PI agent sessions stop after context compaction. Our benchmarks show the model itself is rock-solid. The issue must be in how the PI framework handles:
- Context compaction (may lose instructions or state)
- Session resumption after compaction
- Error handling when model response is slow at large contexts

### 4. ik_llama.cpp would improve speed, not fix the core issue
- ik_llama would likely boost tok/s from ~95 to ~130+ at small contexts
- At large contexts, the bottleneck is prefill (prompt processing), which ik_llama optimizes for MoE models
- But since the model never crashes, the PI framework is the actual bottleneck to fix

## Next Steps

1. **Investigate PI framework compaction behavior** — check how pi handles context compaction, does it resume work?
2. **Consider ik_llama.cpp** for speed improvement (recommended, but separate from the session stop issue)
3. **Reduce ctx-size to 65536** — most PI sessions don't need 128K, and smaller ctx means faster prefill
4. **Enable reasoning-budget: -1** — may improve coding quality at the cost of some thinking tokens
