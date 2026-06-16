#!/usr/bin/env bash
# ==============================================================================
# PROJECT:   SWIFTLLM
# FILE:      docker/docker-entrypoint.sh
# AUTHOR:    Peter A. Aldrich Jr.
# ------------------------------------------------------------------------------
# Container entrypoint. Translates SWIFTLLM_* environment variables into the
# right `swiftllm serve` invocation, and provides a few convenience verbs.
#
# Verbs (first argument):
#   serve            Start the OpenAI-compatible API server (DEFAULT)
#   rebuild          Rebuild + reinstall the wheel from source (devel image only)
#   shell | bash     Drop into an interactive shell
#   swiftllm ...     Pass through directly to the swiftllm CLI
#   <anything else>  Executed verbatim
# Licensed under the Apache License, Version 2.0
# ==============================================================================
set -euo pipefail

# ---- helpers -----------------------------------------------------------------
is_true() {
    case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
        1|true|yes|on) return 0 ;;
        *) return 1 ;;
    esac
}

log() { printf '\033[0;36m[swiftllm]\033[0m %s\n' "$*" >&2; }

banner() {
    local ver gpu
    ver="$(python3 -c 'import swiftllm; print(swiftllm.__version__)' 2>/dev/null || echo '?')"
    log "SwiftLLM v${ver}  |  python $(python3 -c 'import sys;print("%d.%d"%sys.version_info[:2])' 2>/dev/null || echo '?')"
    if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
        gpu="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | paste -sd', ' -)"
        log "GPU: ${gpu:-detected}"
    else
        log "GPU: none visible (CPU mode). For GPU pass --gpus all / nvidia runtime."
    fi
    log "Model dir: ${SWIFTLLM_MODEL_DIR:-<default>}"
}

# ---- serve: build the swiftllm serve command from env + passthrough ----------
do_serve() {
    local args=()
    local has_model=false

    # Did the caller already pass a model on the command line?
    for a in "$@"; do
        case "$a" in -m|--model) has_model=true ;; esac
    done

    if ! $has_model; then
        if [[ -z "${SWIFTLLM_MODEL:-}" ]]; then
            log "ERROR: no model specified."
            log "Set SWIFTLLM_MODEL=<hf-id-or-path> (env) or pass:  serve -m <model>"
            log "Example: docker run ... -e SWIFTLLM_MODEL='Qwen/Qwen2.5-0.5B-Instruct-GGUF:qwen2.5-0.5b-instruct-q4_k_m.gguf'"
            exit 2
        fi
        args+=(-m "${SWIFTLLM_MODEL}")
    fi

    args+=(--host "${SWIFTLLM_HOST:-0.0.0.0}" --port "${SWIFTLLM_PORT:-8000}")

    # Optional knobs — only added when the env var is set (exact CLI flag names).
    [[ -n "${SWIFTLLM_TENSOR_PARALLEL_SIZE:-}" ]] && args+=(--tensor-parallel-size "${SWIFTLLM_TENSOR_PARALLEL_SIZE}")
    [[ -n "${SWIFTLLM_GPU_MEMORY_UTILIZATION:-}" ]] && args+=(--gpu-memory-utilization "${SWIFTLLM_GPU_MEMORY_UTILIZATION}")
    [[ -n "${SWIFTLLM_MAX_MODEL_LEN:-}" ]] && args+=(--max-model-len "${SWIFTLLM_MAX_MODEL_LEN}")
    [[ -n "${SWIFTLLM_QUANTIZATION:-}" ]] && args+=(--quantization "${SWIFTLLM_QUANTIZATION}")
    [[ -n "${SWIFTLLM_DTYPE:-}" ]] && args+=(--dtype "${SWIFTLLM_DTYPE}")
    is_true "${SWIFTLLM_TRUST_REMOTE_CODE:-}" && args+=(--trust-remote-code)
    is_true "${SWIFTLLM_ENABLE_PREFIX_CACHING:-}" && args+=(--enable-prefix-caching)
    # NOTE: SWIFTLLM_API_KEY / SWIFTLLM_RLM / SWIFTLLM_DV are read by the server
    # from the environment directly, so we deliberately do NOT echo them onto the
    # command line (keeps secrets out of `ps`).

    # Extra free-form args, then anything passed after the `serve` verb.
    # shellcheck disable=SC2206
    [[ -n "${SWIFTLLM_SERVE_ARGS:-}" ]] && args+=(${SWIFTLLM_SERVE_ARGS})
    args+=("$@")

    banner
    log "exec: swiftllm serve ${args[*]}"
    exec swiftllm serve "${args[@]}"
}

# ---- rebuild: dynamic in-place rebuild from mounted source (devel image) -----
do_rebuild() {
    local src="${SWIFTLLM_SRC:-/opt/swiftllm/src}"
    local feats="${SWIFTLLM_FEATURES:-cuda}"
    if ! command -v maturin >/dev/null 2>&1; then
        log "ERROR: 'rebuild' needs the build toolchain. Use the devel image"
        log "       (target: devel) — the slim runtime image cannot rebuild."
        exit 3
    fi
    [[ -d "$src" ]] || { log "ERROR: source not found at $src (bind-mount your checkout there)."; exit 3; }
    log "Rebuilding SwiftLLM from $src (features=$feats) ..."
    ( cd "$src" \
        && maturin build --release --no-default-features --features "$feats" --out /tmp/sl-wheels \
        && python3 -m pip install --force-reinstall --no-deps /tmp/sl-wheels/swiftllm-*.whl \
        && rm -rf /tmp/sl-wheels )
    log "Rebuild complete. New version: $(python3 -c 'import swiftllm,importlib;importlib.reload(swiftllm);print(swiftllm.__version__)' 2>/dev/null || echo '?')"
}

# ---- dispatch ----------------------------------------------------------------
verb="${1:-serve}"
case "$verb" in
    serve)
        shift || true
        do_serve "$@"
        ;;
    rebuild)
        shift || true
        do_rebuild "$@"
        # If asked, serve after rebuilding: `rebuild --then-serve`
        if [[ "${1:-}" == "--then-serve" ]]; then shift; do_serve "$@"; fi
        ;;
    shell|bash)
        shift || true
        exec bash "$@"
        ;;
    sh)
        shift || true
        exec sh "$@"
        ;;
    swiftllm)
        # `docker run ... swiftllm generate -m ... -p ...`
        exec "$@"
        ;;
    *)
        # Anything else: run it verbatim (e.g. `python -c ...`, `nvidia-smi`).
        exec "$@"
        ;;
esac
