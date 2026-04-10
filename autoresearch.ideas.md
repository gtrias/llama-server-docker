# Autoresearch Ideas — Optimal 3-Model Setup

## Benchmark Improvements
- [ ] Fix GLM-4.7-Flash scoring — save actual responses and manually verify quality. The 100 t/s + APEX #1 suggest it's being unfairly penalized by keyword matching
- [ ] Add time-weighted penalty to composite score — currently a 21s response scores nearly as well as a 3s response if quality keywords match
- [ ] Add prefill time measurement — the current measurement only captures decode speed. Prompt processing is the real pain point (especially for 27B)
- [ ] Add LLM-as-judge scoring — use a cloud model (or the best local model) to evaluate response quality instead of keyword matching
- [ ] Add real agentic task test — actually have the model call tools via function calling API, not just generate tool call text

## Models to Test
- [ ] Qwen3-Coder-Flash 30B-A3B — purpose-built for agents (Cline/Roo/Kilo). May need Q3 quant to fit 24GB
- [ ] Devstral Small 2 — mentioned as daily driver alternative in Reddit, strong on Next.js tasks
- [ ] Different quantization levels for winning models (Q5_K_M, Q6_K for 27B; Q4_K_XL vs Q4_K_M for Gemma4-26B)
- [ ] Re-test Qwen3.5-35B-A3B with MXFP4_MOE quant (the Reddit post author used this specifically)

## llama.cpp Configuration Optimization
- [ ] Test speculative decoding (draft model) to speed up 27B without losing quality
- [ ] Test different KV cache types (q8_0 vs q4_0) impact on speed vs quality
- [ ] Test MTP (multi-token prediction) if available in llama.cpp build
- [ ] Test parallel=2 vs parallel=1 for each model
- [ ] Test different ctx-size values (smaller = faster prefill)

## Server Architecture
- [ ] Test models-max=2 to keep a fast model loaded alongside quality model
- [ ] Benchmark model swap time (how long does it take to unload/load a different model)
- [ ] Test if keeping models in RAM cache speeds up reload
