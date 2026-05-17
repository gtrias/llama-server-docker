# Which Model Should I Use?

## 🥇 Default choice (when in doubt)
**qwen36-apex** — Use this for everything. Fast, high quality, fits comfortably in 24GB VRAM.

---

## Quick Decision Tree

```
Need vision (screenshots, diagrams, images)?
  → qwen36-apex  (or qwen36-27b / qwen36-27b-mtp)

Long session (>30 min, lots of context)?
  → Gemma 4 26B

Debugging complex code / fixing bugs?
  → qwen36-apex

Want maximum throughput on prompts you'll repeat rarely?
  → qwen36-27b-mtp  (MTP speculative decoding, ~1.8x faster)

Quick task / cron job / short answer?
  → Gemma 4 26B

VRAM running tight / model keeps crashing mid-session?
  → Gemma 4 26B
```

---

## One-Liner Per Model

| Model | Use it when... | Don't use it when... |
|-------|---------------|---------------------|
| **qwen36-apex** | You want it to just work | — |
| **qwen36-27b** | You want dense Qwen3.6 quality with vision | You need the absolute fastest |
| **qwen36-27b-mtp** | Speed matters and prompts vary | Long shared prefixes (DeltaNet can't reuse prefix cache) |
| **Gemma 4 26B** | Speed matters, or session is long | Debugging complex interconnected bugs |
| **Gemma 4 31B** | You need to analyze an image at higher quality | Session might go long (96% VRAM, will OOM) |

---

## For Specific Tools

### Pi Agent
**qwen36-apex** — Best agent tool-calling and format consistency.

### Pi Crons / Channels
**Gemma 4 26B** — Fastest, lowest VRAM, won't crash during long automated runs.

### OpenWebUI Chat
**Gemma 4 26B** for speed, **qwen36-apex** for complex topics, **Gemma 4 31B** if you paste images.

### OpenCode
**qwen36-apex** — Best at understanding and fixing code.
