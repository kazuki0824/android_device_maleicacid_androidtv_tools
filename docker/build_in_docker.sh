#!/usr/bin/env bash
set -euo pipefail

PRODUCT="${1:-}"
if [[ -z "${PRODUCT}" ]]; then
  echo "Usage: $0 <r86s_tv_virtio|qemu_tv_virtio>" >&2
  exit 1
fi

source build/envsetup.sh
lunch ${PRODUCT}-userdebug
m -j$(nproc) espimage-install
m -j$(nproc) otapackage || m -j$(nproc) bacon

echo "Build complete."
