#!/bin/bash
# Auto-download missing models from HuggingFace
# Parses models.ini for hf-repo and hf-file fields

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

    # Skip if no download info
    if [ -z "$repo" ] || [ -z "$file" ]; then
        continue
    fi

    if [ -f "$path" ]; then
        log_info "✓ $section: already present"
        skip_count=$((skip_count + 1))
    else
        log_info "⬇ $section: downloading $repo/$file ..."
        if python3 -c "from huggingface_hub import hf_hub_download; hf_hub_download('$repo', '$file', local_dir='$CACHE_DIR')" 2>&1; then
            log_info "✓ $section: downloaded successfully"
            download_count=$((download_count + 1))
        else
            log_error "✗ $section: download failed"
            fail_count=$((fail_count + 1))
        fi
    fi

    # Also download mmproj if specified
    mmproj="${mmproj_path[$section]:-}"
    mmproj_file="${mmproj_hf_file[$section]:-}"
    if [ -n "$mmproj" ] && [ -n "$mmproj_file" ] && [ ! -f "$mmproj" ]; then
        # The mmproj filename in HF repo may differ from the local path
        # (e.g., repo has "mmproj-BF16.gguf" but preset expects "mmproj-35b-BF16.gguf")
        # Download to a temp name, then rename to the expected path
        mmproj_basename=$(basename "$mmproj")
        hf_downloaded="$CACHE_DIR/$mmproj_file"
        log_info "⬇ $section mmproj: downloading $repo/$mmproj_file → $mmproj_basename ..."
        if python3 -c "from huggingface_hub import hf_hub_download; hf_hub_download('$repo', '$mmproj_file', local_dir='$CACHE_DIR')" 2>&1; then
            # Rename if HF filename differs from expected path
            if [ "$hf_downloaded" != "$mmproj" ] && [ -f "$hf_downloaded" ]; then
                mv "$hf_downloaded" "$mmproj"
                log_info "  renamed $mmproj_file → $mmproj_basename"
            fi
            log_info "✓ $section mmproj: downloaded successfully"
            download_count=$((download_count + 1))
        else
            log_error "✗ $section mmproj: download failed"
            fail_count=$((fail_count + 1))
        fi
    fi
done

log_info ""
log_info "Auto-download complete: $download_count downloaded, $skip_count already present, $fail_count failed"

if [ "$fail_count" -gt 0 ]; then
    log_warn "Some models failed to download. Server will start but those models won't be available."
fi
