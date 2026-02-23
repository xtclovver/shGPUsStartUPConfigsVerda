#!/bin/bash
# =============================================================================
# ComfyUI + WAN 2.2 Rapid Mega AIO NSFW v12.2 — Verda.com
# GPU: 1x RTX PRO 6000 (96GB VRAM)
# Volume: 70GB NVMe (models persist between sessions)
# =============================================================================

set -euo pipefail

COMFY_DIR="/root/ComfyUI"
VOLUME_DIR=""

CHECKPOINT_URL="https://huggingface.co/Phr00t/WAN2.2-14B-Rapid-AllInOne/resolve/main/Mega-v12/wan2.2-rapid-mega-aio-nsfw-v12.2.safetensors"
CLIP_VISION_URL="https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/clip_vision/clip_vision_h.safetensors"
WORKFLOW_URL="https://raw.githubusercontent.com/xtclovver/shGPUsStartUPConfigsVerda/refs/heads/main/comfy_wf_wan2.2-ti2v-aio_uncensored.json"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[$(date +%H:%M:%S)]${NC} $1"; }
warn() { echo -e "${YELLOW}[$(date +%H:%M:%S)] WARN:${NC} $1"; }
err()  { echo -e "${RED}[$(date +%H:%M:%S)] ERROR:${NC} $1"; exit 1; }

START_TIME=$(date +%s)

# --- Volume detection ---
log "Detecting volume..."
for candidate in /mnt/volume_* /mnt/data /mnt/storage; do
    if [ -d "$candidate" ] && mountpoint -q "$candidate" 2>/dev/null; then
        VOLUME_DIR="$candidate"; break
    fi
done

if [ -z "$VOLUME_DIR" ]; then
    EXTRA_DISK=$(lsblk -dpno NAME,TYPE 2>/dev/null | grep 'disk' | awk '{print $1}' | while read d; do
        if ! lsblk -no MOUNTPOINT "$d" 2>/dev/null | grep -qv '^$'; then echo "$d"; fi
    done | head -1)
    if [ -n "${EXTRA_DISK:-}" ]; then
        [ -b "${EXTRA_DISK}1" ] && EXTRA_DISK="${EXTRA_DISK}1"
        FSTYPE=$(blkid -o value -s TYPE "$EXTRA_DISK" 2>/dev/null || true)
        [ -z "$FSTYPE" ] && { log "Formatting ${EXTRA_DISK}..."; mkfs.ext4 -q "$EXTRA_DISK"; }
        VOLUME_DIR="/mnt/models"; mkdir -p "$VOLUME_DIR"
        mount "$EXTRA_DISK" "$VOLUME_DIR"
        log "Mounted ${EXTRA_DISK} -> ${VOLUME_DIR}"
    fi
fi

if [ -z "$VOLUME_DIR" ]; then
    warn "No volume found. Models stored locally (lost on termination)."
    VOLUME_DIR="/root/models_cache"
fi
mkdir -p "${VOLUME_DIR}/checkpoints" "${VOLUME_DIR}/clip_vision"
log "Volume: ${VOLUME_DIR}"

# --- GPU check ---
log "Checking GPU..."
command -v nvidia-smi &>/dev/null || err "nvidia-smi not found."
nvidia-smi --query-gpu=name,memory.total --format=csv,noheader

# --- System deps ---
log "Installing system packages..."
apt-get update -qq && apt-get install -y -qq git python3-venv python3-pip aria2 ffmpeg wget > /dev/null 2>&1

# --- ComfyUI ---
if [ ! -d "$COMFY_DIR" ]; then
    log "Cloning ComfyUI..."
    git clone --depth 1 https://github.com/comfyanonymous/ComfyUI.git "$COMFY_DIR"
else
    log "ComfyUI exists, updating..."
    cd "$COMFY_DIR" && git pull --ff-only 2>/dev/null || true
fi

# --- Python deps ---
log "Installing Python dependencies..."
cd "$COMFY_DIR"
pip install --upgrade pip -q
pip install -r requirements.txt -q

# --- VideoHelperSuite ---
CUSTOM_NODES="${COMFY_DIR}/custom_nodes"
if [ ! -d "${CUSTOM_NODES}/ComfyUI-VideoHelperSuite" ]; then
    log "Installing VideoHelperSuite..."
    git clone --depth 1 https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git \
        "${CUSTOM_NODES}/ComfyUI-VideoHelperSuite"
fi
[ -f "${CUSTOM_NODES}/ComfyUI-VideoHelperSuite/requirements.txt" ] && \
    pip install -r "${CUSTOM_NODES}/ComfyUI-VideoHelperSuite/requirements.txt" -q

# --- Download models to volume ---
download_model() {
    local url="$1" dest="$2" min_bytes="$3"
    if [ -f "$dest" ]; then
        local sz; sz=$(stat -c%s "$dest" 2>/dev/null || echo 0)
        if [ "$sz" -ge "$min_bytes" ]; then
            log "  Cached: $(basename $dest) ($(( sz / 1073741824 )) GB)"
            return 0
        fi
        rm -f "$dest"
    fi
    log "  Downloading: $(basename $dest)..."
    aria2c -x 16 -s 16 -k 1M --console-log-level=warn \
        -d "$(dirname $dest)" -o "$(basename $dest)" "$url"
}

log "Checking models..."
download_model "$CHECKPOINT_URL" \
    "${VOLUME_DIR}/checkpoints/wan2.2-rapid-mega-aio-nsfw-v12.2.safetensors" 20000000000 &
P1=$!
download_model "$CLIP_VISION_URL" \
    "${VOLUME_DIR}/clip_vision/clip_vision_h.safetensors" 3000000000 &
P2=$!
wait $P1 || err "Checkpoint download failed"
wait $P2 || err "CLIP vision download failed"

# --- Symlink models ---
log "Linking models..."
mkdir -p "${COMFY_DIR}/models/checkpoints" "${COMFY_DIR}/models/clip_vision"
ln -sf "${VOLUME_DIR}/checkpoints/wan2.2-rapid-mega-aio-nsfw-v12.2.safetensors" \
    "${COMFY_DIR}/models/checkpoints/wan2.2-rapid-mega-aio-nsfw-v12.2.safetensors"
ln -sf "${VOLUME_DIR}/clip_vision/clip_vision_h.safetensors" \
    "${COMFY_DIR}/models/clip_vision/clip_vision_h.safetensors"

# --- Download workflow from GitHub ---
log "Downloading workflow from GitHub..."
wget -q -O "${COMFY_DIR}/workflow_wan22_i2v.json" "$WORKFLOW_URL" || err "Workflow download failed"
log "Workflow saved: ${COMFY_DIR}/workflow_wan22_i2v.json"

# --- Launch ---
END_TIME=$(date +%s)
log "Setup done in $((END_TIME - START_TIME))s"
log ""
log "Models on volume: ${VOLUME_DIR}"
log "SSH tunnel:  ssh -L 8188:localhost:8188 root@<IP>"
log "Browser:     http://localhost:8188"
log "Workflow:    Menu -> Load -> workflow_wan22_i2v.json"
log ""

cd "$COMFY_DIR"
python3 main.py \
    --listen 0.0.0.0 \
    --port 8188 \
    --highvram \
    --gpu-only \
    --disable-auto-launch
