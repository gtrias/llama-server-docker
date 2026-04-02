# Deployment Guide - Llama Server Docker

## 🎯 Overview

This guide will help you migrate from your current manual llama-server setup to a modern Docker-based solution with model switching, WebUI, and proper infrastructure integration.

## 📋 Current Setup Analysis

Your current configuration:
- **Manual Process**: Running llama-server directly on host
- **Qwen Model**: `Qwen3-Coder-Next` with 162K context, port 11434
- **GLM Model**: `GLM-4.7-Flash-REAP` with 32K context
- **Resource Usage**: ~46GB RAM out of 94GB total
- **Management**: Manual process start/stop, no auto-restart

## 🚀 Deployment Steps

### Phase 1: Preparation (5 minutes)

1. **Stop your current manual server:**
   ```bash
   # Find the process
   ps aux | grep llama-server
   
   # Stop it gracefully
   pkill -TERM llama-server
   
   # Or use the specific PID from your output (2898560)
   kill 2898560
   ```

2. **Verify no conflicts:**
   ```bash
   # Check port 11434 is free
   netstat -tulpn | grep 11434
   
   # Verify no other llama-server processes
   ps aux | grep llama-server | grep -v grep
   ```

### Phase 2: Build and Deploy (10 minutes)

1. **Navigate to project directory:**
   ```bash
   cd /home/genar/src/llama-server-docker
   ```

2. **Review configuration:**
   ```bash
   # Check your current model settings
   cat config/models.conf
   
   # Verify docker-compose settings
   cat docker-compose.yml
   ```

3. **Build Docker image:**
   ```bash
   docker-compose build
   
   # This will:
   # - Pull the latest llama.cpp server-cuda image
   # - Add custom tools (curl, wget, jq)
   # - Configure health checks
   # - Set up proper networking
   ```

4. **Start services:**
   ```bash
   docker-compose up -d
   
   # This will:
   # - Start llama-server on port 11434 (preserving your current port)
   # - Enable GPU support
   # - Connect to your Traefik network
   # - Set up model manager interface
   ```

### Phase 3: Verification (5 minutes)

1. **Check container status:**
   ```bash
   docker-compose ps
   docker-compose logs llama-server
   ```

2. **Verify server health:**
   ```bash
   # Health check
   curl http://localhost:11434/health
   
   # Check model properties
   curl http://localhost:11434/props
   ```

3. **Test WebUI access:**
   - Main WebUI: http://llama.casa.genar.me
   - Model Manager: http://llama-models.casa.genar.me

### Phase 4: Model Switching Testing (10 minutes)

1. **Test Qwen model:**
   ```bash
   ./switch-model.sh qwen
   
   # Wait for restart (~30 seconds)
   # Verify: http://llama.casa.genar.me
   ```

2. **Test GLM model:**
   ```bash
   ./switch-model.sh glm
   
   # Wait for restart (~20 seconds - smaller context)
   # Verify: http://llama.casa.genar.me
   ```

3. **Test API endpoints:**
   ```bash
   # Chat completion test
   curl http://localhost:11434/v1/chat/completions \
     -H "Content-Type: application/json" \
     -d '{
       "model": "qwen-coder",
       "messages": [{"role": "user", "content": "Hello!"}]
     }'
   ```

## 🔧 Customization

### Adjusting Resources

If you need to fine-tune resource usage:

```yaml
# In docker-compose.yml
deploy:
  resources:
    limits:
      memory: 50G    # Adjust based on your needs
    reservations:
      memory: 20G
```

### Adding New Models

1. **Edit model configuration:**
   ```bash
   nano config/models.conf
   ```

2. **Add new model profile:**
   ```ini
   [New-Model]
   description = "Model description"
   repo = "org/model-name-GGUF"
   file = "quantization"
   ctx_size = 32768
   repeat_penalty = 1.0
   temp = 0.7
   top_p = 1.0
   min_p = 0.01
   parallel = 1
   gpu_layers = -1
   alias = "new-model"
   ```

3. **Update switch script:**
   ```bash
   nano switch-model.sh
   # Add new case for the model
   ```

### Custom Parameters

Modify environment variables in `docker-compose.yml`:

```yaml
environment:
  - TEMPERATURE=0.8          # Adjust creativity
  - TOP_P=0.9               # Adjust diversity
  - REPEAT_PENALTY=1.1      # Reduce repetition
  - CTX_SIZE=32768          # Adjust context size
  - PARALLEL=2              # Adjust parallel processing
```

## 📊 Performance Monitoring

### Real-time Monitoring

```bash
# Container resources
docker stats llama-server

# GPU usage
watch -n 1 nvidia-smi

# Server logs
docker-compose logs -f llama-server
```

### Performance Comparison

**Manual Setup vs Docker:**

| Metric | Manual | Docker | Notes |
|--------|--------|--------|-------|
| Startup Time | ~2 min | ~3 min | Initial download, then cached |
| Memory Usage | ~46GB | ~48GB | Slight overhead for container |
| GPU Access | Direct | Native | Same performance |
| Restart Time | Manual | ~30s | Auto-restart on failure |
| Model Switch | Manual | Scripted | One-command switching |

## 🐛 Troubleshooting

### Common Issues

1. **Port Already in Use:**
   ```bash
   # Check what's using port 11434
   sudo lsof -i :11434
   
   # Kill the process if needed
   sudo kill -9 <PID>
   ```

2. **GPU Not Detected:**
   ```bash
   # Verify NVIDIA Docker runtime
   docker run --rm --gpus all nvidia/cuda:11.0-base nvidia-smi
   
   # Check nvidia-container-toolkit
   which nvidia-container-cli
   ```

3. **Memory Issues:**
   ```bash
   # Check available memory
   free -h
   
   # Monitor container memory
   docker stats llama-server --no-stream
   
   # Reduce context size if needed
   # Edit CTX_SIZE in docker-compose.yml
   ```

4. **Model Download Issues:**
   ```bash
   # Check logs for download progress
   docker-compose logs -f llama-server
   
   # Models are cached in Docker volume
   docker volume inspect llama-server-docker_cache
   ```

### Rollback Procedure

If you need to revert to manual setup:

```bash
# Stop Docker containers
docker-compose down

# Start manual server (if needed)
llama-server --host 0.0.0.0 --port 11434 \
  -hf Qwen/Qwen3-Coder-Next-GGUF:Q4_K_M \
  --repeat-penalty 1.0 --temp 0.7 --top-p 1.0 \
  --min-p 0.01 --jinja -fitc 162144
```

## 📈 Next Steps

### Immediate Benefits

After deployment, you'll have:

✅ **Automated Management**: Auto-restart on failure
✅ **Easy Model Switching**: One-command model changes
✅ **Modern WebUI**: Rich interface with advanced features
✅ **Proper Monitoring**: Health checks and logging
✅ **SSL/TLS**: Automatic HTTPS via Traefik
✅ **Scalability**: Easy to add more models or instances

### Future Enhancements

1. **Multiple Model Instances**: Run different models simultaneously
2. **Load Balancing**: Distribute requests across multiple instances
3. **Monitoring Dashboard**: Add Prometheus/Grafana integration
4. **Backup Automation**: Automated configuration and chat backups
5. **API Gateway**: Centralized API management

## 🎓 Key Features to Explore

### WebUI Capabilities

1. **Document Processing**
   - Upload PDFs and text files
   - Automatic context injection
   - Image support for vision models

2. **Conversation Management**
   - Branch conversations from any point
   - Parallel conversations
   - Import/Export functionality

3. **Advanced Features**
   - Custom JSON schemas for constrained generation
   - Math rendering (LaTeX)
   - Developer tools and API testing

### API Features

1. **OpenAI-Compatible Endpoints**
   - Chat completions
   - Streaming responses
   - Function calling support

2. **Management Endpoints**
   - Health checks
   - Model properties
   - Slot management

## 📞 Support

For issues or questions:
- Check logs: `docker-compose logs -f`
- Review config: `cat docker-compose.yml`
- Test health: `curl http://localhost:11434/health`

## 🎉 Success Criteria

You'll know the deployment is successful when:

1. ✅ Container runs without errors
2. ✅ Health endpoint returns OK
3. ✅ WebUI loads and responds
4. ✅ Model switching works smoothly
5. ✅ API endpoints function correctly
6. ✅ Resource usage is acceptable

**Estimated Total Time: 30-45 minutes**
**Difficulty Level: Intermediate**
**Risk Level: Low** (Easy rollback if needed)
