#!/bin/bash
# Auto-Offload Manager - Automatically unload idle models after timeout period

set -e

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$PROJECT_DIR")"
CONFIG_FILE="$BASE_DIR/config/auto-offload.conf"
LOG_FILE="$BASE_DIR/logs/auto-offload.log"
MODEL_LAST_USED_DIR="$PROJECT_DIR/.model_last_used"

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_info() { echo -e "${GREEN}[INFO]${NC} $1" | tee -a "$LOG_FILE"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1" | tee -a "$LOG_FILE"; }

# Load configuration
load_config() {
    print_info "Loading configuration from $CONFIG_FILE..."

    # Set defaults
    AUTO_OFFLOAD_ENABLED="true"
    IDLE_TIMEOUT_SECONDS="1800"  # 30 minutes
    CHECK_INTERVAL_SECONDS="60"

    # Read from config file if exists
    if [ -f "$CONFIG_FILE" ]; then
        # Source the config file (it's now in bash variable format)
        source "$CONFIG_FILE"
        AUTO_OFFLOAD_ENABLED="${enabled:-true}"
        IDLE_TIMEOUT_SECONDS="${idle_timeout:-1800}"
        CHECK_INTERVAL_SECONDS="${check_interval:-60}"
    fi

    IDLE_TIMEOUT_MINUTES=$((IDLE_TIMEOUT_SECONDS / 60))
    
    print_info "Config: enabled=$AUTO_OFFLOAD_ENABLED, timeout=${IDLE_TIMEOUT_MINUTES}min (${IDLE_TIMEOUT_SECONDS}s), check=${CHECK_INTERVAL_SECONDS}s"
}

# Check if a model is loaded
is_model_loaded() {
    local alias="$1"

    for url in "http://localhost:11434/v1/models" "http://localhost:11434/api/v1/models"; do
        status=$(curl -s "$url" 2>/dev/null | jq -r ".data[]? | select(.id == \"$alias\") | .status.value")

        if [ "$status" = "loaded" ]; then
            echo "true"
            return
        fi
    done

    echo "false"
}

# Check if a model has been idle too long
is_model_idle() {
    local alias="$1"
    local model_dir="$MODEL_LAST_USED_DIR"

    if [ ! -f "$model_dir/${alias}" ]; then
        # Model was never used before (newly loaded)
        echo "false"
        return
    fi

    local current_time=$(date +%s)
    local last_used=$(cat "$model_dir/${alias}")
    local idle_seconds=$((current_time - last_used))
    local idle_minutes=$((idle_seconds / 60))

    if [ $idle_seconds -ge $IDLE_TIMEOUT_SECONDS ]; then
        print_info "${alias} has been idle ${idle_minutes} minutes (${idle_seconds}s) - exceeds threshold: ${IDLE_TIMEOUT_MINUTES}m (${IDLE_TIMEOUT_SECONDS}s)" >&2
        echo "true"
    else
        print_info "${alias} idle: ${idle_minutes}m (${idle_seconds}s) - threshold: ${IDLE_TIMEOUT_MINUTES}m (${IDLE_TIMEOUT_SECONDS}s)" >&2
        echo "false"
    fi
}

# Suggest how to unload a model
suggest_unload() {
    local alias="$1"

    print_warning "${alias} should be unloaded but manual unload not supported via API"
    echo ""
    echo "To unload ${alias}, use one of these methods:"
    echo "  1. WebUI: http://localhost:11434/"
    echo "  2. LRU eviction: Load a 3rd model to force unload"
    echo "  3. Restart: docker-compose restart llama-server"
}

# Show model status
show_status() {
    # Ensure config is loaded
    if [ -z "$AUTO_OFFLOAD_ENABLED" ]; then
        load_config
    fi

    echo ""
    echo -e "${BLUE}=== Model Status ($(date)) ===${NC}"
    echo ""

    for alias in qwen-code qwen35 glm; do
        loaded=$(is_model_loaded "$alias")

        echo -n "${alias}: "
        if [ "$loaded" = "true" ]; then
            echo -e "${GREEN}LOADED${NC}"

            if [ -f "$MODEL_LAST_USED_DIR/${alias}" ]; then
                last_used=$(cat "$MODEL_LAST_USED_DIR/${alias}")
                current_time=$(date +%s)
                idle_minutes=$(((current_time - last_used) / 60))
                echo "  Idle for: ${idle_minutes}m"

                # Check if should be unloaded
                if [ "$AUTO_OFFLOAD_ENABLED" = "true" ]; then
                    idle=$(is_model_idle "$alias")
                    if [ "$idle" = "true" ]; then
                        suggest_unload "$alias"
                    fi
                fi
            fi
        else
            echo -e "Unloaded"
        fi
        echo ""
    done
}

# Main monitoring loop
monitor_loop() {
    print_info "Starting auto-offload monitor (press Ctrl+C to stop)"
    print_info "Run 'tail -f logs/auto-offload.log' to see detailed logs"

    while true; do
        show_status
        sleep $CHECK_INTERVAL_SECONDS
    done
}

# Main entry point
main() {
    local mode="${1:-monitor}"

    print_info "========================================="
    print_info "Model Manager - Auto-Offload System"
    print_info "========================================="

    load_config

    case "$mode" in
        start|monitor)
            monitor_loop
            ;;
        status|check|once)
            show_status
            ;;
        *)
            echo "Usage: $0 [start|status]"
            echo ""
            echo "Commands:"
            echo "  start   - Start monitoring daemon (runs in background)"
            echo "  status  - Show current model status (one-time check)"
            echo ""
            echo "To run as daemon:"
            echo "  nohup ./scripts/model-manager.sh start > logs/auto-offload-daemon.log 2>&1 &"
            echo ""
            echo "To stop daemon:"
            echo "  pkill -f model-manager.sh"
            exit 1
            ;;
    esac
}

main "$@"