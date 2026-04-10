# Which Model Should I Use?

## 🥇 Default choice (when in doubt)
**Qwen3.5 27B** — Use this for everything. It's the most reliable all-rounder.

---

## Quick Decision Tree

```
Need vision (screenshots, diagrams, images)?
  → Gemma 4 31B

Long session (>30 min, lots of context)?
  → Gemma 4 26B

Debugging complex code / fixing bugs?
  → Qwen3.5 27B

Quick task / cron job / short answer?
  → Gemma 4 26B

VRAM running tight / model keeps crashing mid-session?
  → Gemma 4 26B
```

---

## One-Liner Per Model

| Model | Use it when... | Don't use it when... |
|-------|---------------|---------------------|
| **Qwen3.5 27B** | You want it to just work | Session is very long (>50K tokens) |
| **Gemma 4 26B** | Speed matters, or session is long | Debugging complex interconnected bugs |
| **Gemma 4 31B** | You need to analyze an image | Session might go long (96% VRAM, will OOM) |
| **Qwen3.5 35B** | Both 27B models are busy | You care about speed |
| **Qwen3.5 9B** | Never | Seriously, never |

---

## For Specific Tools

### Pi Agent
**Qwen3.5 27B** — Best agent tool-calling, most consistent format, trusted daily driver.

### Pi Crons / Channels
**Gemma 4 26B** — Fastest, lowest VRAM, won't crash during long automated runs.

### OpenWebUI Chat
**Gemma 4 26B** for speed, **Qwen3.5 27B** for complex topics, **Gemma 4 31B** if you paste images.

### OpenCode
**Qwen3.5 27B** — Best at understanding and fixing code.
