# Model Management - Quick Reference

## Essential Commands

```bash
# Check status of all models
./scripts/check-models.sh

# Load a specific model
./scripts/load-model.sh qwen      # or glm

# Unload a specific model
./scripts/unload-model.sh qwen    # or glm

# Track usage manually (after WebUI usage)
./scripts/track-usage.sh qwen     # or glm

# Start auto-offload daemon
./scripts/model-manager.sh start

# Stop auto-offload daemon
pkill -f model-manager.sh

# Make API call with usage tracking
./scripts/api-wrapper.sh http://localhost:11434/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "qwen", "messages": [{"role": "user", "content": "Hello"}]}'
```

## Configuration

Edit `config/models.ini`:

```ini
[auto_offload]
enabled = true              # Enable/disable
idle_timeout_minutes = 30   # Unload after 30 min idle
check_interval_seconds = 60  # Check every 60 seconds
```

## How It Works

1. **Make API call** → Model is loaded automatically (on-demand)
2. **Record usage** → Timestamp saved in `.model_last_used/<model>`
3. **Auto-offload daemon runs** → Checks idle time every 60 seconds
4. **Model idle > 30 min** → Model is unloaded

## Tips

- Use `./scripts/api-wrapper.sh` for automatic tracking
- Check status with `./scripts/check-models.sh` anytime
- Disable auto-offload temporarily for important work:
  ```bash
  pkill -f model-manager.sh  # Stop daemon
  ./scripts/load-model.sh qwen  # Load your model
  # ... do your work ...
  ./scripts/model-manager.sh start  # Restart daemon
  ```

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Models not unloading | Check daemon running: `ps aux \| grep model-manager` |
| Usage not tracking | Check timestamps: `ls -la .model_last_used/` |
| Can't connect to API | Check container: `docker-compose ps` |
| High memory after unload | Restart container: `docker-compose restart llama-server` |

## More Info

See `AUTO-OFFLOAD-GUIDE.md` for complete documentation.