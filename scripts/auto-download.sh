#!/bin/bash
# Auto-download missing models from HuggingFace
# Parses models.ini for hf-repo and hf-file fields

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

PRESET_FILE="${1:-/config/models.ini}"
CACHE_DIR="${2:-/root/.cache/llama.cpp}"

log_info()  { echo -e "${GREEN}[DOWNLOAD]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[DOWNLOAD]${NC} $1"; }
log_error() { echo -e "${RED}[DOWNLOAD]${NC} $1"; }

if [ ! -f "$PRESET_FILE" ]; then
    log_warn "No preset file found at $PRESET_FILE, skipping auto-download"
    exit 0
fi

mkdir -p "$CACHE_DIR"

# Parse ini file and download missing models
current_section=""
declare -A model_path hf_repo hf_file mmproj_path mmproj_hf_file

while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue

    if [[ "$line" =~ ^\[([^\]]+)\] ]]; then
        current_section="${BASH_REMATCH[1]}"
        continue
    fi

    if [[ "$line" =~ ^[[:space:]]*([^=]+)[[:space:]]*=[[:space:]]*(.*)[[:space:]]*$ ]]; then
        key=$(echo "${BASH_REMATCH[1]}" | xargs)
        value=$(echo "${BASH_REMATCH[2]}" | xargs)

        case "$key" in
            model)          model_path[$current_section]="$value" ;;
            hf-repo)        hf_repo[$current_section]="$value" ;;
            hf-file)        hf_file[$current_section]="$value" ;;
            mmproj)         mmproj_path[$current_section]="$value" ;;
            mmproj-hf-file) mmproj_hf_file[$current_section]="$value" ;;
        esac
    fi
done < "$PRESET_FILE"

download_count=0
skip_count=0
fail_count=0

for section in "${!model_path[@]}"; do
    repo="${hf_repo[$section]:-}"
    file="${hf_file[$section]:-}"
    path="${model_path[$section]}"

    [ -z "$repo" ] || [ -z "$file" ] && continue

    if [ -f "$path" ]; then
        log_info "✓ $section: already present"
        ((skip_count++))
    else
        log_info "⬇ $section: downloading $repo/$file ..."
        if huggingface-cli download "$repo" "$file" --local-dir "$CACHE_DIR" --local-dir-use-symlinks False 2>&1; then
            log_info "✓ $section: downloaded successfully"
            ((download_count++))
        else
            log_error "✗ $section: download failed"
            ((fail_count++))
        fi
    fi

    # Also download mmproj if specified
    mmproj="${mmproj_path[$section]:-}"
    mmproj_file="${mmproj_hf_file[$section]:-}"
    if [ -n "$mmproj" ] && [ -n "$mmproj_file" ] && [ ! -f "$mmproj" ]; then
        log_info "⬇ $section mmproj: downloading $repo/$mmproj_file ..."
        if huggingface-cli download "$repo" "$mmproj_file" --local-dir "$CACHE_DIR" --local-dir-use-symlinks False 2>&1; then
            log_info "✓ $section mmproj: downloaded successfully"
            ((download_count++))
        else
            log_error "✗ $section mmproj: download failed"
            ((fail_count++))
        fi
    fi
done

log_info ""
log_info "Auto-download complete: $download_count downloaded, $skip_count already present, $fail_count failed"

if [ "$fail_count" -gt 0 ]; then
    log_warn "Some models failed to download. Server will start but those models won't be available."
fi
