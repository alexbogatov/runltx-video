#!/bin/bash
set -eo pipefail

export GIT_TERMINAL_PROMPT=0

echo "===================================================="
echo "[Startup] Initializing LTX 2.5 Runner Environment"
echo "===================================================="

# 1. Platform & GPU Auto-Discovery
#
# HYPERSTACK_API_KEY is present in the env file on EVERY platform (it is shared
# config), so a bare key check misdetects everything as hyperstack. Probe the
# actual machine instead.
is_hyperstack() {
    # 1. OpenStack / NexGen Cloud instance metadata
    if curl -s --connect-timeout 1 http://169.254.169.254/openstack/latest/meta_data.json 2>/dev/null | grep -qi "nexgen\|hyperstack"; then
        return 0
    fi

    # 2. DMI BIOS / product identifiers
    local dmi_data
    dmi_data="$(cat /sys/class/dmi/id/sys_vendor /sys/class/dmi/id/product_name /sys/class/dmi/id/chassis_asset_tag 2>/dev/null || true)"
    if echo "$dmi_data" | grep -qi "nexgen\|hyperstack"; then
        return 0
    fi

    # 3. Hyperstack agent / provision flags from VM bootstrap
    if [ -d "/etc/hyperstack" ] || [ -f "/var/log/hyperstack-init.log" ]; then
        return 0
    fi

    return 1
}

if [ -n "$MODAL_TASK_ID" ] || [ -n "$MODAL_IS_REMOTE" ] || [ -n "$MODAL_ENVIRONMENT" ]; then
    export RUNNER_PLATFORM="modal"
elif [ -n "$VAST_CONTAINERLABEL" ] || [ -n "$CONTAINER_ID" ] || [ -n "$VAST_TCP_PORT_22" ]; then
    export RUNNER_PLATFORM="vastai"
elif [ -n "$LIUM_POD_ID" ] || [ -f "/etc/lium/pod.json" ] || [ -d "/lium-cipher" ]; then
    # Lium mounts its cipher volume at /lium-cipher and its k0s root is
    # distinctive. LIUM_POD_ID (injected by .admin/deploy.lium.sh) is the
    # strongest signal, but deploy.lium.sh may be pasted without it, so fall
    # back to filesystem markers rather than to the shared API key.
    export RUNNER_PLATFORM="lium"
elif is_hyperstack; then
    export RUNNER_PLATFORM="hyperstack"
else
    export RUNNER_PLATFORM="generic"
fi

if command -v nvidia-smi &> /dev/null; then
    export RUNNER_GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -n 1 | xargs)
    export RUNNER_GPU_COUNT=$(nvidia-smi --query-gpu=name --format=csv,noheader | wc -l | xargs)
    export RUNNER_GPU_VRAM=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader | head -n 1 | xargs)
else
    export RUNNER_GPU_NAME="None"
    export RUNNER_GPU_COUNT="0"
    export RUNNER_GPU_VRAM="0"
fi

MACHINE_ID=$(hostname)
API_BASE_URL="${API_BASE_URL:-https://api.runltx.com}"

echo "[Platform] Runtime  : $RUNNER_PLATFORM"
echo "[Hardware] GPU Model: $RUNNER_GPU_NAME ($RUNNER_GPU_COUNT detected, $RUNNER_GPU_VRAM VRAM)"
echo "===================================================="

# ==============================================================================
# 2. CALL /v1/worker/on (Runs BEFORE ComfyUI or any processing starts)
# ==============================================================================
echo "[Billing] Registering worker startup session via /v1/worker/on..."
SESSION_PAYLOAD=$(cat <<EOF
{
  "machine_id": "${MACHINE_ID}",
  "provider": "${RUNNER_PLATFORM}",
  "gpu_name": "${RUNNER_GPU_NAME}",
  "gpu_count": ${RUNNER_GPU_COUNT},
  "gpu_vram": "${RUNNER_GPU_VRAM}"
}
EOF
)

SESSION_RESPONSE=$(curl -s -X POST "${API_BASE_URL}/v1/worker/on" \
    -H "Content-Type: application/json" \
    -H "worker-auth: ${WORKER_API_SECRET}" \
    -H "x-machine-id: ${MACHINE_ID}" \
    -d "${SESSION_PAYLOAD}" || echo '{"success":false}')

export WORKER_SESSION_ID=$(echo "$SESSION_RESPONSE" | node -e "
    const fs = require('fs');
    try {
        const res = JSON.parse(fs.readFileSync(0, 'utf-8'));
        if (res.success && res.session_id) process.stdout.write(res.session_id);
    } catch (_) {}
")

if [ -n "$WORKER_SESSION_ID" ]; then
    echo "[Billing] Active Worker Session ID: ${WORKER_SESSION_ID}"
else
    echo "[Billing Warning] Could not initialize session tracking."
fi

# ==============================================================================
# 3. Storage Setup & Symlinks
# ==============================================================================
STORAGE_DIR="/workspace/models"

pkill -f "main.py" || true
rm -f /app/ComfyUI/user/comfyui.db.lock || true

mkdir -p "${STORAGE_DIR}/diffusion_models" \
         "${STORAGE_DIR}/text_encoders" \
         "${STORAGE_DIR}/vae" \
         "${STORAGE_DIR}/latent_upscale_models" \
         "/workspace/output" \
         /app/ComfyUI/models

ln -sfn /workspace/output /app/ComfyUI/output
ln -sfn "${STORAGE_DIR}/diffusion_models" /app/ComfyUI/models/diffusion_models
ln -sfn "${STORAGE_DIR}/text_encoders" /app/ComfyUI/models/text_encoders
ln -sfn "${STORAGE_DIR}/vae" /app/ComfyUI/models/vae
ln -sfn "${STORAGE_DIR}/latent_upscale_models" /app/ComfyUI/models/latent_upscale_models

# ==============================================================================
# 3.5 Download Models via dl.sh
# ==============================================================================
echo "[Startup] Executing dl.sh to download models..."

if [ -f "/app/dl.sh" ]; then
    echo "[Startup] Running /app/dl.sh..."
    bash /app/dl.sh
elif [ -f "./dl.sh" ]; then
    echo "[Startup] Running ./dl.sh..."
    bash ./dl.sh
else
    echo "[Error] dl.sh not found in /app or current directory!"
    exit 1
fi

# ==============================================================================
# 4. Launch ComfyUI & Worker Daemon
# ==============================================================================
cd /app
/opt/venv/bin/python3 /app/ComfyUI/main.py --listen 0.0.0.0 --port 8188 --highvram --fast &
COMFY_PID=$!

echo "[Startup] Waiting for ComfyUI on port 8188..."
until curl -s http://127.0.0.1:8188/system_stats > /dev/null 2>&1; do
    sleep 1
done
echo "[Startup] ComfyUI ready. Launching worker daemon..."

# Execute worker (handles queue polling until inactivity timeout)
node worker.js
WORKER_EXIT_CODE=$?

# Kill ComfyUI background process
kill -9 $COMFY_PID 2>/dev/null || true

# ==============================================================================
# 5. CALL /v1/worker/off & HIBERNATE (Runs at teardown)
# ==============================================================================
echo "[Billing] Finalizing worker session via /v1/worker/off..."

STATS_FILE="/tmp/worker_stats.json"
JOBS_PROCESSED=0
TOTAL_GEN_TIME=0

if [ -f "$STATS_FILE" ]; then
    JOBS_PROCESSED=$(node -e "try { console.log(JSON.parse(fs.readFileSync('$STATS_FILE')).jobs_processed || 0); } catch(_) { console.log(0); }")
    TOTAL_GEN_TIME=$(node -e "try { console.log(JSON.parse(fs.readFileSync('$STATS_FILE')).total_generation_time_sec || 0); } catch(_) { console.log(0); }")
fi

OFF_PAYLOAD=$(cat <<EOF
{
  "session_id": "${WORKER_SESSION_ID}",
  "machine_id": "${MACHINE_ID}",
  "jobs_processed": ${JOBS_PROCESSED},
  "total_generation_time_sec": ${TOTAL_GEN_TIME}
}
EOF
)

curl -s -X POST "${API_BASE_URL}/v1/worker/off" \
    -H "Content-Type: application/json" \
    -H "worker-auth: ${WORKER_API_SECRET}" \
    -H "x-machine-id: ${MACHINE_ID}" \
    -d "${OFF_PAYLOAD}" || true

echo "[Billing] Session closed."

# --- Lium Pod Deletion ---
if [ "$RUNNER_PLATFORM" = "lium" ]; then
    echo "[Teardown] Shutting down Lium pod to prevent idle compute charges..."
    LIUM_API_URL="${LIUM_API_URL:-https://lium.io/api}"

    if [ -z "$LIUM_API_KEY" ]; then
        echo "[Teardown] LIUM_API_KEY not set; cannot delete pod. Terminating PID 1..."
        kill -s TERM 1 2>/dev/null || true
    else
        # Identity comes only from LIUM_POD_ID, injected by .admin/deploy.lium.sh.
        # It is never inferred: $HOSTNAME is a 12-char container id the API
        # rejects (422 uuid_parsing), and a name lookup from inside the pod
        # cannot reliably single this pod out - guessing wrong would delete
        # somebody else's pod on idle teardown.
        LIUM_ID="${LIUM_POD_ID:-${LIUM_POD_UUID:-}}"

        if [ -z "$LIUM_ID" ]; then
            echo "[Teardown] LIUM_POD_ID is empty; skipping Lium API delete."
            echo "[Teardown] Set LIUM_POD_ID in .env at deploy time to enable self-deletion."
            echo "[Teardown] The pod will keep billing until stopped from the Lium dashboard."
        elif [[ "$LIUM_ID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
            # Fire and forget: the DELETE tears down this pod, which kills the
            # container mid-request, so the response is never received or logged.
            echo "[Teardown] Deleting Lium pod ${LIUM_ID}..."
            curl -s -X DELETE "${LIUM_API_URL}/pods/${LIUM_ID}" \
                -H "X-API-Key: ${LIUM_API_KEY}" \
                -H "accept: application/json" >/dev/null 2>&1 || true
        else
            echo "[Teardown] LIUM_POD_ID is not a valid 36-char UUID (got '${LIUM_ID}')."
            echo "[Teardown] Refusing to delete; stop the pod from the Lium dashboard."
        fi

        kill -s TERM 1 2>/dev/null || true
    fi

# --- Hyperstack Hibernation ---
elif [ "$RUNNER_PLATFORM" = "hyperstack" ] && [ -n "$HYPERSTACK_API_KEY" ]; then
    echo "[Teardown] Requesting Hyperstack VM Hibernation for host: ${MACHINE_ID}..."
    HYPERSTACK_API_URL="${HYPERSTACK_API_URL:-https://infrahub-api.nexgencloud.com/v1}"
    
    VM_ID=$(curl -s -H "api_key: ${HYPERSTACK_API_KEY}" -H "accept: application/json" \
        "${HYPERSTACK_API_URL}/core/virtual-machines" | \
        node -e "
            const fs = require('fs');
            try {
                const data = JSON.parse(fs.readFileSync(0, 'utf-8'));
                const match = (data.instances || []).find(v => v.name && v.name.toLowerCase() === '${MACHINE_ID}'.toLowerCase());
                if (match) process.stdout.write(String(match.id));
            } catch (_) {}
        ")

    if [ -n "$VM_ID" ]; then
        echo "[Teardown] Hibernating VM ${VM_ID}..."
        curl -s -H "api_key: ${HYPERSTACK_API_KEY}" \
            "${HYPERSTACK_API_URL}/core/virtual-machines/${VM_ID}/hibernate?retain_ip=true" || true
    fi

# --- Vast.ai Stop Instance ---
elif [ "$RUNNER_PLATFORM" = "vastai" ]; then
    echo "[Teardown] Shutting down Vast.ai instance to prevent idle compute charges..."
    
    # Resolve instance ID: checks CONTAINER_ID, VAST_CONTAINERLABEL, or hostname
    VAST_ID="${CONTAINER_ID:-${VAST_CONTAINERLABEL:-${MACHINE_ID}}}"

    if [ -n "$CONTAINER_API_KEY" ] && [ -n "$VAST_ID" ]; then
        echo "[Teardown] Calling Vast.ai REST API for instance ${VAST_ID}..."
        curl -s -X PUT "https://console.vast.ai/api/v0/instances/${VAST_ID}/" \
            -H "Authorization: Bearer ${CONTAINER_API_KEY}" \
            -H "Content-Type: application/json" \
            -d '{"state": "stopped"}' || true
    elif command -v vastai >/dev/null 2>&1 && [ -n "$VAST_ID" ]; then
        echo "[Teardown] Calling vastai CLI for instance ${VAST_ID}..."
        vastai stop instance "$VAST_ID" || true
    else
        echo "[Teardown] No Vast API key or CLI found inside container. Terminating PID 1..."
        kill -s TERM 1 2>/dev/null || true
    fi
fi

exit $WORKER_EXIT_CODE
