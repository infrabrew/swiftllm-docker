#!/usr/bin/env bash
# ==============================================================================
# PROJECT:   SWIFTLLM
# FILE:      docker/airgap/load-airgap.sh
# AUTHOR:    Peter A. Aldrich Jr.
# ------------------------------------------------------------------------------
# Offline installer — run INSIDE the extracted bundle on the air-gapped host.
# Loads the SwiftLLM image and restores any bundled models into a Docker volume.
# No internet access required.
#
# Usage:
#   ./load-airgap.sh                  # load image + restore models
#   ./load-airgap.sh --no-models      # load image only
# Licensed under the Apache License, Version 2.0
# ==============================================================================
set -euo pipefail

C='\033[0;36m'; G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; N='\033[0m'
info(){ echo -e "${C}[airgap-load]${N} $*"; }
ok(){   echo -e "${G}[ok]${N} $*"; }
warn(){ echo -e "${Y}[warn]${N} $*"; }
die(){  echo -e "${R}[fail]${N} $*" >&2; exit 1; }

# Locate bundle root: works whether run from the bundle dir or one level up.
BUNDLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$BUNDLE_DIR/image.tar" ]] || BUNDLE_DIR="$BUNDLE_DIR/swiftllm-docker-airgap"
[[ -f "$BUNDLE_DIR/image.tar" ]] || die "image.tar not found. Run this from inside the extracted bundle."

RESTORE_MODELS=true
[[ "${1:-}" == "--no-models" ]] && RESTORE_MODELS=false

command -v docker >/dev/null 2>&1 || die "docker is required on this host"

# ----------------------------------------------------------------------------
# 1. Load the image
# ----------------------------------------------------------------------------
info "Loading image from image.tar ..."
LOADED="$(docker load -i "$BUNDLE_DIR/image.tar")"
echo "$LOADED"
IMAGE="$(echo "$LOADED" | sed -n 's/^Loaded image: //p' | head -1)"
[[ -z "$IMAGE" ]] && IMAGE="$(grep -E '^SWIFTLLM_IMAGE=' "$BUNDLE_DIR/compose/.env" 2>/dev/null | cut -d= -f2-)"
ok "Loaded image: ${IMAGE:-<unknown>}"

# ----------------------------------------------------------------------------
# 2. Restore bundled models into the swiftllm-models volume
# ----------------------------------------------------------------------------
if $RESTORE_MODELS && [[ -d "$BUNDLE_DIR/models" ]] && [[ -n "$(ls -A "$BUNDLE_DIR/models" 2>/dev/null)" ]]; then
    info "Restoring models into volume 'swiftllm-models' ..."
    docker volume create swiftllm-models >/dev/null
    # Use the loaded image itself (it has cp) so we don't need to pull anything.
    docker run --rm \
        -v swiftllm-models:/models \
        -v "$BUNDLE_DIR/models":/src:ro \
        --entrypoint sh "$IMAGE" -c 'cp -rn /src/. /models/ && ls -la /models' \
        || warn "model restore step failed (you can copy them in later)"
    ok "Models restored."
else
    info "No bundled models to restore."
fi

# ----------------------------------------------------------------------------
# 3. Next steps
# ----------------------------------------------------------------------------
cat <<EOF

$(echo -e "${G}SwiftLLM image is installed.${N}")

Next:
  cd "$BUNDLE_DIR/compose"
  \$EDITOR .env          # set SWIFTLLM_MODEL (if not already set)
  ./swiftllmctl up       # starts the server using the loaded image (no build)
  ./swiftllmctl logs -f
  curl http://localhost:8000/health

Note: '.env' is pinned to the bundled image, so 'up' will NOT try to build or
pull. GPU hosts must already have the NVIDIA Container Toolkit installed offline.
EOF
