# Model Management Scripts

This directory contains scripts for automatic model offloading based on usage timing.

## Scripts

| Script | Purpose | Usage |
|--------|---------|-------|
| `check-models.sh` | Check model status, memory usage, and idle times | `./check-models.sh` |
| `load-model.sh` | Trigger model loading (loads on-demand via API) | `./load-model.sh <alias>` |
| `unload-model.sh` | Show options for unloading models | `./unload-model.sh <alias>` |
| `track-usage.sh` | Manually record that a model was used | `./track-usage.sh <alias>` |
| `api-wrapper.sh` | Wrap API calls to auto-track usage | `./api-wrapper.sh [curl command]` |
| `model-manager.sh` | Auto-offload daemon (runs in background) | `./model-manager.sh start` |

## Quick Reference

```bash
# Check status
./check-models.sh

# Track usage (after WebUI usage)
./track-usage.sh qwen

# Load a model
./load-model.sh glm

# Make API call with tracking
./api-wrapper.sh http://localhost:11434/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "qwen", "messages": [{"role": "user", "content": "Hello"}]}'

# Start auto-offload daemon
./model-manager.sh start
```

## How It Works

1. **API calls** → Use `api-wrapper.sh` to wrap your curl commands
2. **Usage tracking** → Timestamps saved in `.model_last_used/<model>`
3. **Daemon monitoring** → Checks every 60 seconds (configurable)
4. **Auto-offload** → Unloads models idle > 30 minutes (configurable)

## Configuration

Edit `../config/models.ini`:

```ini
[auto_offload]
enabled = true
idle_timeout_minutes = 30
check_interval_seconds = 60
```

## More Information

- `../AUTO-OFFLOAD-GUIDE.md` - Complete guide
- `../QUICK-REF.md` - Quick reference card
- `../SUMMARY.md` - Setup summary
- `../test-auto-offload.sh` - Test the system