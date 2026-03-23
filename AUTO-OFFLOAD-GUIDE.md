# Automatic Model Offload Guide

## Problem

Due to memory limits, you cannot keep multiple LLM models loaded simultaneously. You need a system that:

1. Loads a model when you request it
2. Tracks when each model was last used
3. Automatically unloads models after they've been idle for a certain time
4. Allows you to manually switch between models when needed

## Solution

This guide provides a complete system for managing model loading/unloading based on usage timing.

### Architecture

```
┌─────────────────┐
│   Your App/API  │
└────────┬────────┘
         │
         ▼
┌─────────────────┐     ┌──────────────────┐
│  API Wrapper    │────▶│  Usage Tracker   │
│ (timestamps)    │     │  (last_used)     │
└─────────────────┘     └────────┬─────────┘
                                 │
                                 ▼
┌─────────────────┐     ┌──────────────────┐
│ llama.cpp      │◀────│ Auto-Offload     │
│ Server (Docker)│     │ Daemon           │
└─────────────────┘     └──────────────────┘
```

## Setup

### 1. Configure Auto-Offload Settings

Edit `config/models.ini` to configure auto-offload behavior:

```ini
[qwen]
alias = qwen

[glm]
alias = glm

[auto_offload]
enabled = true              # Enable/disable auto-offload
idle_timeout_minutes = 30   # Unload after X minutes of inactivity
check_interval_seconds = 60  # Check every X seconds
```

### 2. Make Scripts Executable

```bash
chmod +x scripts/*.sh
```

### 3. Start the Auto-Offload Daemon

```bash
./scripts/model-manager.sh start
```

The daemon will:
- Check loaded models every `check_interval_seconds`
- Track idle time for each model
- Unload models that have been idle longer than `idle_timeout_minutes`

## Usage

### Method 1: Using the API Wrapper (Recommended)

Wrap your API calls to automatically track usage:

```bash
# Chat completion
./scripts/api-wrapper.sh http://localhost:11434/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen",
    "messages": [
      {"role": "user", "content": "Write a Python function"}
    ]
  }'

# Completion
./scripts/api-wrapper.sh http://localhost:11434/v1/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "glm",
    "prompt": "The quick brown fox"
  }'
```

The wrapper will:
1. Extract the model name from your request
2. Record the current timestamp for that model
3. Execute the API call normally
4. Return the response

### Method 2: Manual Tracking

If you can't use the wrapper, manually record model usage:

```bash
# Record that "qwen" model was just used
current_time=$(date +%s)
echo "$current_time" > .model_last_used/qwen

# Then make your API call normally
curl http://localhost:11434/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "qwen", "messages": ...}'
```

### Method 3: WebUI Usage

Using the WebUI at http://localhost:11434/ automatically loads models. 
To track usage with WebUI, you'll need to call the tracking separately:

```bash
# After using a model via WebUI, record its usage
./scripts/track-usage.sh qwen
```

## Manual Model Management

### Check Model Status

```bash
./scripts/check-models.sh
```

Output:
```
=== Model Status Check ===
API URL: http://localhost:11434

Configured Models:
==================

✓ qwen: LOADED
   Last used: 5m ago

○ glm: Unloaded

Memory Summary:
==============
GPU: 12 GiB / 24 GiB

Container stats:
llama-server    5.0%    15.2GiB / 31.4GiB
```

### Load a Model

```bash
./scripts/load-model.sh qwen
# or
./scripts/load-model.sh glm
```

This will:
1. Record that the model is being used now
2. Trigger the model to load (on-demand loading)
3. Report the status

### Unload a Model

```bash
./scripts/unload-model.sh qwen
# or
./scripts/unload-model.sh glm
```

Note: Manual unloading may not be supported directly via API. The script will show you options:
- Use the WebUI to unload
- Restart the server (unloads all)
- Let the auto-offload daemon handle it

## Auto-Offload Daemon

### Start the Daemon

```bash
./scripts/model-manager.sh start
```

The daemon runs in the background and:
- Checks model status every 60 seconds (configurable)
- Tracks idle time using `.model_last_used/` timestamps
- Unloads models that have been idle longer than the timeout

### Monitor the Daemon

```bash
# View logs
tail -f logs/auto-offload.log

# Check if running
ps aux | grep model-manager
```

### Stop the Daemon

```bash
pkill -f model-manager.sh
# or
killall script
```

## How It Works

### 1. Usage Tracking

When you make an API call (via the wrapper or manually):

```bash
# Timestamp is recorded in .model_last_used/<alias>
echo "$(date +%s)" > .model_last_used/qwen
```

### 2. Auto-Offload Check

The daemon runs periodically:

```bash
for each model:
  if model is loaded:
    last_used = read from .model_last_used/<model>
    idle_time = now - last_used
    
    if idle_time > timeout:
      unload_model()
```

### 3. Model Loading

Models are loaded on-demand when you first use them via:
- API request
- WebUI interaction
- Manual load command

## Configuration Options

Edit `config/models.ini`:

| Option | Description | Default |
|--------|-------------|---------|
| `enabled` | Enable/disable auto-offload | `true` |
| `idle_timeout_minutes` | Minutes of inactivity before unload | `30` |
| `check_interval_seconds` | How often to check (seconds) | `60` |

## Best Practices

### 1. Always Use the API Wrapper

For automatic tracking, wrap all API calls:

```bash
./scripts/api-wrapper.sh [your curl command]
```

### 2. Set Appropriate Timeout

Based on your workflow:
- **Short workflows** (switch frequently): 5-15 minutes
- **Medium workflows**: 15-30 minutes  
- **Long workflows** (keep loaded): 60+ minutes or disable auto-offload

### 3. Monitor Memory Usage

```bash
# Check GPU memory
nvidia-smi

# Check container stats
docker stats llama-server

# Check model status
./scripts/check-models.sh
```

### 4. Manual Override When Needed

For important work, manually load your model:

```bash
# Stop auto-offload temporarily
pkill -f model-manager.sh

# Load your model
./scripts/load-model.sh qwen

# Work on your task...
curl http://localhost:11434/v1/chat/completions ...

# When done, restart auto-offload
./scripts/model-manager.sh start
```

## Troubleshooting

### Models Not Unloading

**Problem**: Auto-offload isn't working, models stay loaded

**Solutions**:
1. Check if daemon is running: `ps aux | grep model-manager`
2. Check logs: `tail -f logs/auto-offload.log`
3. Verify config: `cat config/models.ini | grep auto_offload`
4. Ensure timestamps are being recorded: `ls -la .model_last_used/`
5. llama.cpp may not support manual unloading - use LRU eviction or restart

### Usage Tracking Not Working

**Problem**: Timestamps not being recorded

**Solutions**:
1. Are you using the API wrapper?
2. Check `.model_last_used/` directory exists
3. Manually record usage to test:
   ```bash
   echo "$(date +%s)" > .model_last_used/qwen
   ```

### Cannot Connect to API

**Problem**: API calls failing

**Solutions**:
1. Check container is running: `docker-compose ps`
2. Check logs: `docker-compose logs llama-server`
3. Verify API URL: `export API_URL=http://localhost:11434`
4. Check health endpoint: `curl http://localhost:11434/health`

### Memory Still High After Unload

**Problem**: GPU memory not freed after unloading

**Solutions**:
1. Wait a few moments - cleanup may be delayed
2. Check if model actually unloaded: `curl http://localhost:11434/v1/models | jq`
3. Restart container: `docker-compose restart llama-server`
4. This may be a llama.cpp limitation - consider using LRU eviction instead

## Alternative: LRU Eviction

If auto-offload based on time doesn't work well, llama.cpp has built-in LRU eviction:

```ini
# In models.ini or docker-compose.yml
max_loaded_models = 2  # Keep at most 2 models loaded
```

When you load a 3rd model, the least recently used model is automatically unloaded.

This is simpler and more reliable but doesn't give you time-based control.

## Integration Examples

### Python Integration

```python
import requests
import subprocess
import os

def track_model_usage(model):
    """Record that a model was used"""
    timestamp = int(time.time())
    os.makedirs(".model_last_used", exist_ok=True)
    with open(f".model_last_used/{model}", "w") as f:
        f.write(str(timestamp))

def chat_completion(model, messages):
    """Make API call with usage tracking"""
    track_model_usage(model)
    
    response = requests.post(
        "http://localhost:11434/v1/chat/completions",
        json={
            "model": model,
            "messages": messages
        }
    )
    return response.json()

# Usage
response = chat_completion("qwen", [
    {"role": "user", "content": "Hello!"}
])
```

### Node.js Integration

```javascript
const fs = require('fs');
const path = require('path');

function trackModelUsage(model) {
    const timestamp = Math.floor(Date.now() / 1000);
    const dir = '.model_last_used';
    if (!fs.existsSync(dir)) fs.mkdirSync(dir);
    fs.writeFileSync(path.join(dir, model), timestamp.toString());
}

async function chatCompletion(model, messages) {
    trackModelUsage(model);
    
    const response = await fetch('http://localhost:11434/v1/chat/completions', {
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        body: JSON.stringify({model, messages})
    });
    return await response.json();
}

// Usage
chatCompletion('qwen', [{role: 'user', content: 'Hello!'}]);
```

## Summary

This system provides:

✅ **Automatic unloading** based on idle time
✅ **Manual control** when you need it  
✅ **Usage tracking** via API wrapper or manual recording
✅ **Status monitoring** with detailed reports
✅ **Flexible configuration** for your workflow
✅ **Memory efficient** model management

For questions or issues, check the logs or consult the troubleshooting section.