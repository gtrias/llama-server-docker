#!/bin/bash
set -euo pipefail

# ==============================================================================
# Voxel World Challenge: Can the model build a working game in one HTML file?
# ==============================================================================

BASE_URL="${LLAMA_BASE_URL:-http://localhost:11434/v1}"
MODEL="${1:?Usage: $0 <model-alias> [output-dir]}"
OUTPUT_DIR="${2:-/tmp/voxel-challenge}"

mkdir -p "$OUTPUT_DIR"

log() { echo "[voxel] $1" >&2; }

# Build prompt from file to avoid shell escaping issues
PROMPT_FILE="/tmp/voxel-challenge-prompt.txt"
cat > "$PROMPT_FILE" << 'PROMPT_EOF'
Create a minimal voxel world in a single HTML file using Three.js.

CDN: https://unpkg.com/three@0.170.0/build/three.module.js

Requirements:
- First-person camera with WASD movement and mouse look (pointer lock on click)
- Procedural terrain using noise (implement a simple noise function, no external lib)
- At least 4 different block types (grass, dirt, stone, wood) with distinct colors
- Block breaking (left click) and placing (right click) using raycasting
- Simple gravity and collision detection — player stays on blocks, cant walk through them
- Flat or gently hilly terrain (16x16 or 32x32 chunk)
- Crosshair in the center of the screen
- Block type selector (number keys 1-4 to switch active block)
- HTML/CSS/JS all in one file, no build steps, must work by opening in a browser

Output ONLY the complete HTML file. No explanation, no markdown, just the code starting with <!DOCTYPE html>.
PROMPT_EOF

PROMPT=$(cat "$PROMPT_FILE")

log "Sending voxel world challenge to $MODEL..."

start_time=$(date +%s%3N)

RESPONSE_JSON="/tmp/voxel-response-${MODEL}.json"
curl -s --max-time 300 "$BASE_URL/chat/completions" \
    -H "Content-Type: application/json" \
    -d "$(jq -n \
        --arg model "$MODEL" \
        --arg prompt "$PROMPT" \
        --argjson max_tokens 16384 \
        '{
            model: $model,
            messages: [
                {role: "system", content: "You are an expert game developer. Output only code, no explanation. Produce complete, working, copy-pasteable code."},
                {role: "user", content: $prompt}
            ],
            max_tokens: $max_tokens,
            temperature: 0.3,
            stream: false
        }')" > "$RESPONSE_JSON" 2>&1

end_time=$(date +%s%3N)
total_ms=$((end_time - start_time))

content=$(jq -r '.choices[0].message.content // ""' "$RESPONSE_JSON" 2>/dev/null)
if [ -z "$content" ]; then
    content=$(jq -r '.choices[0].message.reasoning_content // ""' "$RESPONSE_JSON" 2>/dev/null)
fi

prompt_tokens=$(jq -r '.usage.prompt_tokens // 0' "$RESPONSE_JSON" 2>/dev/null)
completion_tokens=$(jq -r '.usage.completion_tokens // 0' "$RESPONSE_JSON" 2>/dev/null)

if [ -z "$content" ]; then
    log "ERROR: No response from model"
    echo "METRIC voxel_total_score=0"
    echo "METRIC voxel_gen_ms=$total_ms"
    exit 1
fi

# Extract HTML — strip markdown code fences
html_content=$(echo "$content" | sed 's/^```html//' | sed 's/^```//' | sed 's/```$//')

if ! echo "$html_content" | head -5 | grep -qi "DOCTYPE\|html\|<head"; then
    html_content=$(echo "$content" | sed -n '/<!DOCTYPE/,/<\/html>/p' 2>/dev/null)
fi

if [ -z "$html_content" ] || [ ${#html_content} -lt 500 ]; then
    log "ERROR: No valid HTML extracted (${#html_content} bytes)"
    echo "METRIC voxel_total_score=0"
    echo "METRIC voxel_gen_ms=$total_ms"
    echo "METRIC voxel_file_bytes=0"
    exit 1
fi

output_file="$OUTPUT_DIR/$MODEL.html"
printf '%s' "$html_content" > "$output_file"
file_bytes=$(wc -c < "$output_file")

log "Generated $output_file ($file_bytes bytes, $((total_ms/1000))s)"

# ==============================================================================
# Automated checks
# ==============================================================================

score=0

has_pattern() {
    echo "$html_content" | grep -qiE "$1" 2>/dev/null
}

log ""
log "Automated checks:"

# Structure (5 pts)
if has_pattern "DOCTYPE";              then score=$((score+2)); log "  [PASS] Valid HTML (+2)";            else log "  [FAIL] Valid HTML"; fi
if has_pattern "three@0.170.0";        then score=$((score+1)); log "  [PASS] Three.js CDN (+1)";           else log "  [FAIL] Three.js CDN"; fi
if has_pattern "type.*module";         then score=$((score+1)); log "  [PASS] ES module (+1)";              else log "  [FAIL] ES module"; fi
if has_pattern "<script";              then score=$((score+1)); log "  [PASS] Script tag (+1)";             else log "  [FAIL] Script tag"; fi

# Game mechanics (5 pts)
if has_pattern "KeyW|keydown|wasd";    then score=$((score+1)); log "  [PASS] WASD movement (+1)";         else log "  [FAIL] WASD movement"; fi
if has_pattern "pointerlock|PointerLock|mousemove"; then score=$((score+1)); log "  [PASS] Mouse look (+1)"; else log "  [FAIL] Mouse look"; fi
if has_pattern "gravity|velocity.*y|falling";       then score=$((score+1)); log "  [PASS] Gravity (+1)";    else log "  [FAIL] Gravity"; fi
if has_pattern "raycast|break|remove.*block";        then score=$((score+1)); log "  [PASS] Block breaking (+1)"; else log "  [FAIL] Block breaking"; fi
if has_pattern "place.*block|add.*block|InstancedMesh"; then score=$((score+1)); log "  [PASS] Block placing (+1)"; else log "  [FAIL] Block placing"; fi

# World features (5 pts)
if has_pattern "grass|dirt|stone|wood|blockType";    then score=$((score+1)); log "  [PASS] Block types (+1)";         else log "  [FAIL] Block types"; fi
if has_pattern "noise|terrain|heightMap|procedural"; then score=$((score+2)); log "  [PASS] Terrain gen (+2)";         else log "  [FAIL] Terrain gen"; fi
if has_pattern "crosshair|reticle";                  then score=$((score+1)); log "  [PASS] Crosshair (+1)";           else log "  [FAIL] Crosshair"; fi
if has_pattern "activeBlock|blockType.*=|hotbar";    then score=$((score+1)); log "  [PASS] Block selector (+1)";      else log "  [FAIL] Block selector"; fi

# Code quality (5 pts)
if has_pattern "requestAnimationFrame|animate";      then score=$((score+1)); log "  [PASS] Game loop (+1)";           else log "  [FAIL] Game loop"; fi
if has_pattern "collision|intersect|bounding";       then score=$((score+1)); log "  [PASS] Collision (+1)";           else log "  [FAIL] Collision"; fi
if has_pattern "AmbientLight|DirectionalLight|HemisphereLight"; then score=$((score+1)); log "  [PASS] Lighting (+1)"; else log "  [FAIL] Lighting"; fi
if has_pattern "Scene|renderer|PerspectiveCamera";   then score=$((score+1)); log "  [PASS] Scene setup (+1)";         else log "  [FAIL] Scene setup"; fi
if has_pattern "script.*src.*unpkg|script.*src.*cdn|type.*module"; then score=$((score+1)); log "  [PASS] No build deps (+1)"; else log "  [FAIL] No build deps"; fi

echo ""
log "Score: $score / 20"
log "Generation: $((total_ms/1000))s, $completion_tokens tokens, $file_bytes bytes"

# Emit metrics
echo "METRIC voxel_total_score=$score"
echo "METRIC voxel_gen_ms=$total_ms"
echo "METRIC voxel_gen_s=$((total_ms / 1000))"
echo "METRIC voxel_file_bytes=$file_bytes"
echo "METRIC voxel_completion_tokens=$completion_tokens"
echo "METRIC voxel_prompt_tokens=$prompt_tokens"

log ""
log "Output: $output_file"
log "Open with: xdg-open $output_file"
