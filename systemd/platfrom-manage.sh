#!/usr/bin/env bash
# platfrom stack lifecycle helper: vLLM + embedding, ordered start + blocking restart.
#
# Design:
#   - stop removes the Deployments/Services from etcd so kubelet cannot recreate
#     stale pods while the node is shutting down.
#   - start is idempotent: clean stale resources, wait for apiserver, wait for
#     the device plugin, run a canary GPU pod, then apply vLLM first, embedding second.
#   - restart blocks on delete (waits for pods to actually terminate and release
#     the GPUs) before re-applying, so old/new instances never overlap.
#   - a canary pod is used because "allocatable == N" does not mean the GPUs are
#     healthy. A Running pod that requests 1 GPU is the real admission check.
#
# GPU pinning (drift-free):
#   Workloads declare their GPU by UUID via NVIDIA_VISIBLE_DEVICES, injected by the
#   NVIDIA container toolkit — NOT through the device plugin's arbitrary allocation.
#   The UUID follows the physical card across reboots and slot swaps, so the
#   assignment never drifts. The deployments carry ${LLM_GPU_UUIDS} / ${EMBED_GPU_UUID}
#   placeholders which this script substitutes at apply time.
#
# Override these via environment variables or systemd Environment=:
#   KUBECONFIG, REPO_DIR, NAMESPACE, GPU_NODE_NAME, EXPECTED_GPUS,
#   DEVICE_PLUGIN_NAMESPACE, DEVICE_PLUGIN_DS, CANARY_IMAGE,
#   LLM_GPU_UUIDS, EMBED_GPU_UUID

set -u

export KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${REPO_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
DEPLOY_YAML="$REPO_DIR/yaml/qwen3-35b-deployment.yaml"
EMBED_YAML="$REPO_DIR/yaml/embedding-deployment.yaml"
NODEPORT_YAML="$REPO_DIR/yaml/qwen3-35b-nodeport.yaml"

NAMESPACE="${NAMESPACE:-llm-serving}"
GPU_NODE_NAME="${GPU_NODE_NAME:-}"
EXPECTED_GPUS="${EXPECTED_GPUS:-2}"
DEVICE_PLUGIN_NAMESPACE="${DEVICE_PLUGIN_NAMESPACE:-kube-system}"
DEVICE_PLUGIN_DS="${DEVICE_PLUGIN_DS:-nvidia-device-plugin}"
CANARY_IMAGE="${CANARY_IMAGE:-docker.io/vllm/vllm-openai:v0.31.0}"
CANARY_NAME="${CANARY_NAME:-gpu-canary}"

# GPU UUID pinning. LLM gets the tensor-parallel cards, embedding gets the rest.
# Find UUIDs with: nvidia-smi --query-gpu=index,uuid,pci.bus_id --format=csv
LLM_GPU_UUIDS="${LLM_GPU_UUIDS:-}"
EMBED_GPU_UUID="${EMBED_GPU_UUID:-}"

log() { echo "[platfrom-manage] $*"; }

wait_apiserver() {
    local n=0
    until kubectl get --raw=/healthz >/dev/null 2>&1; do
        n=$((n + 1))
        if [ "$n" -ge 90 ]; then
            log "ERROR: apiserver not ready within 180s"
            exit 1
        fi
        sleep 2
    done
    log "apiserver ready"
}

detect_gpu_node() {
    if [ -n "$GPU_NODE_NAME" ]; then
        return 0
    fi
    GPU_NODE_NAME="$(kubectl get nodes -l nvidia.com/gpu.present=true \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [ -z "$GPU_NODE_NAME" ]; then
        log "ERROR: no GPU node found; set GPU_NODE_NAME or add the nvidia.com/gpu.present=true label"
        exit 1
    fi
    log "detected GPU node: $GPU_NODE_NAME"
}

wait_gpu_plugin() {
    if ! kubectl -n "$DEVICE_PLUGIN_NAMESPACE" rollout status \
        ds/"$DEVICE_PLUGIN_DS" --timeout=300s; then
        log "ERROR: device plugin DaemonSet not ready within 300s"
        exit 1
    fi
    # With UUID pinning the plugin's allocatable is informational only; just
    # confirm the plugin is alive. Canary below is the real admission check.
    log "device plugin ready (allocatable not used for gating under UUID pinning)"
}

canary_gate() {
    local attempt=1
    while [ "$attempt" -le 8 ]; do
        log "canary admission check $attempt/8"
        kubectl delete pod "$CANARY_NAME" -n "$NAMESPACE" \
            --ignore-not-found --wait=false >/dev/null 2>&1 || true

        kubectl apply -f - >/dev/null 2>&1 <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $CANARY_NAME
  namespace: $NAMESPACE
spec:
  restartPolicy: Never
  runtimeClassName: nvidia
  containers:
    - name: canary
      image: $CANARY_IMAGE
      imagePullPolicy: IfNotPresent
      command: ["sleep", "30"]
      resources:
        limits:
          nvidia.com/gpu: 1
EOF

        local n=0
        while [ "$n" -lt 45 ]; do
            local phase
            phase="$(kubectl get pod "$CANARY_NAME" -n "$NAMESPACE" \
                -o jsonpath='{.status.phase}' 2>/dev/null || true)"

            if [ "$phase" = "Running" ]; then
                log "canary Running -> GPU really allocatable"
                if ! kubectl delete pod "$CANARY_NAME" -n "$NAMESPACE" \
                    --wait=true --timeout=90s >/dev/null 2>&1; then
                    log "WARN: canary delete timed out; forcing cleanup"
                    kubectl delete pod "$CANARY_NAME" -n "$NAMESPACE" \
                        --force --grace-period=0 --wait=true --timeout=30s \
                        >/dev/null 2>&1 || true
                fi
                return 0
            fi

            if [ "$phase" = "Failed" ] || [ "$phase" = "Succeeded" ]; then
                break
            fi
            n=$((n + 1))
            sleep 2
        done

        kubectl delete pod "$CANARY_NAME" -n "$NAMESPACE" \
            --ignore-not-found --wait=false >/dev/null 2>&1 || true
        log "canary not ready (GPU may still be unhealthy); retry in 20s"
        sleep 20
        attempt=$((attempt + 1))
    done

    log "ERROR: canary failed 8 times; refusing to apply"
    exit 1
}

wait_pods_gone() {
    # Block until the stack's pods are actually gone (GPUs released).
    local n=0 left
    while true; do
        left=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null \
            | grep -E "^(qwen3-35b|mineru|embedding)-" | grep -vE "Completed|Succeeded" | wc -l)
        if [ "$left" = "0" ]; then
            log "old pods fully terminated; GPUs released"
            return 0
        fi
        n=$((n + 1))
        if [ "$n" -ge 150 ]; then
            log "WARN: still $left pods after 300s; forcing cleanup"
            kubectl delete pods -n "$NAMESPACE" --force --grace-period=0 \
                -l app=qwen3-35b >/dev/null 2>&1 || true
            kubectl delete pods -n "$NAMESPACE" --force --grace-period=0 \
                -l app=mineru >/dev/null 2>&1 || true
            sleep 5
            return 0
        fi
        sleep 2
    done
}

# Substitute the GPU UUID placeholders and apply. Uses envsubst so the repo
# stays free of hardware-specific UUIDs.
apply_with_pinning() {
    local yaml="$1"
    if [ -z "$LLM_GPU_UUIDS" ] && [ -z "$EMBED_GPU_UUID" ]; then
        kubectl apply -f "$yaml"
        return
    fi
    LLM_GPU_UUIDS="$LLM_GPU_UUIDS" EMBED_GPU_UUID="$EMBED_GPU_UUID" \
        envsubst '${LLM_GPU_UUIDS} ${EMBED_GPU_UUID}' < "$yaml" | kubectl apply -f -
}

cleanup_stale() {
    kubectl delete -f "$DEPLOY_YAML" -f "$EMBED_YAML" -f "$NODEPORT_YAML" \
        --ignore-not-found --wait=false >/dev/null 2>&1 || true
    kubectl delete pod "$CANARY_NAME" -n "$NAMESPACE" \
        --ignore-not-found --wait=false >/dev/null 2>&1 || true
    log "stale resources cleaned (if any)"
}

cmd_start() {
    wait_apiserver
    detect_gpu_node
    cleanup_stale
    wait_gpu_plugin
    canary_gate
    apply_with_pinning "$DEPLOY_YAML"
    kubectl apply -f "$NODEPORT_YAML"
    log "vLLM applied (pinned: ${LLM_GPU_UUIDS:-device-plugin}); startupProbe guards model load"
    apply_with_pinning "$EMBED_YAML"
    log "embedding applied (pinned: ${EMBED_GPU_UUID:-device-plugin})"
}

cmd_stop() {
    if kubectl delete -f "$DEPLOY_YAML" -f "$EMBED_YAML" -f "$NODEPORT_YAML" \
        --ignore-not-found --wait=false >/dev/null 2>&1; then
        log "delete requested (etcd removal; kubelet may still be draining)"
    else
        log "WARN: delete failed (apiserver may be down); start path will clean up"
    fi
}

cmd_restart() {
    log "restart: blocking delete until pods terminate (GPUs released), then re-apply"
    kubectl delete -f "$DEPLOY_YAML" -f "$EMBED_YAML" -f "$NODEPORT_YAML" \
        --ignore-not-found --wait=true --timeout=180s >/dev/null 2>&1 || true
    wait_pods_gone
    cmd_start
}

cmd_verify_stopped() {
    if kubectl get deploy qwen3-35b -n "$NAMESPACE" >/dev/null 2>&1; then
        log "WARN: deployment still exists (shutdown race); next start will clean it"
    fi
    exit 0
}

case "${1:-}" in
    start) cmd_start ;;
    stop) cmd_stop ;;
    restart) cmd_restart ;;
    verify-stopped) cmd_verify_stopped ;;
    *)
        echo "usage: $0 {start|stop|restart|verify-stopped}" >&2
        exit 2
        ;;
esac
