#!/usr/bin/env bash
# qwen3-35b lifecycle helper: ordered start + clean stop.
#
# Design:
#   - stop removes the Deployment/Service from etcd so kubelet cannot recreate
#     stale pods while the node is shutting down.
#   - start is idempotent: clean stale resources, wait for apiserver, wait for
#     the device plugin, run a canary GPU pod, then apply.
#   - a canary pod is used because "allocatable == 2" does not mean the GPUs are
#     healthy. A Running pod that requests 1 GPU is the real admission check.
#
# Override these via environment variables or systemd Environment=:
#   KUBECONFIG, REPO_DIR, NAMESPACE, GPU_NODE_NAME, EXPECTED_GPUS,
#   DEVICE_PLUGIN_NAMESPACE, DEVICE_PLUGIN_DS, CANARY_IMAGE

set -u

export KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${REPO_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
DEPLOY_YAML="$REPO_DIR/yaml/qwen3-35b-deployment.yaml"
NODEPORT_YAML="$REPO_DIR/yaml/qwen3-35b-nodeport.yaml"

NAMESPACE="${NAMESPACE:-llm-serving}"
GPU_NODE_NAME="${GPU_NODE_NAME:-}"
EXPECTED_GPUS="${EXPECTED_GPUS:-2}"
DEVICE_PLUGIN_NAMESPACE="${DEVICE_PLUGIN_NAMESPACE:-kube-system}"
DEVICE_PLUGIN_DS="${DEVICE_PLUGIN_DS:-nvidia-device-plugin}"
CANARY_IMAGE="${CANARY_IMAGE:-docker.io/vllm/vllm-openai:v0.31.0}"
CANARY_NAME="${CANARY_NAME:-gpu-canary}"

log() { echo "[qwen3-35b-manage] $*"; }

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

    local n=0
    until [ "$(kubectl get node "$GPU_NODE_NAME" \
        -o jsonpath='{.status.allocatable.nvidia\.com/gpu}' 2>/dev/null)" = "$EXPECTED_GPUS" ]; do
        n=$((n + 1))
        if [ "$n" -ge 60 ]; then
            log "ERROR: GPU resource not registered within 120s"
            exit 1
        fi
        sleep 2
    done
    log "device plugin ready; node reports nvidia.com/gpu=$EXPECTED_GPUS (not a health check)"
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
                # Wait for the pod to disappear so the GPU is fully released
                # before the real workload is created.
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

cleanup_stale() {
    kubectl delete -f "$DEPLOY_YAML" -f "$NODEPORT_YAML" \
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
    kubectl apply -f "$DEPLOY_YAML" -f "$NODEPORT_YAML"
    log "applied; model load is guarded by startupProbe (up to 40min)"
}

cmd_stop() {
    if kubectl delete -f "$DEPLOY_YAML" -f "$NODEPORT_YAML" \
        --ignore-not-found --wait=false >/dev/null 2>&1; then
        log "delete requested (etcd removal; kubelet may still be draining)"
    else
        log "WARN: delete failed (apiserver may be down); start path will clean up"
    fi
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
    verify-stopped) cmd_verify_stopped ;;
    *)
        echo "usage: $0 {start|stop|verify-stopped}" >&2
        exit 2
        ;;
esac
