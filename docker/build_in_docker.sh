#!/usr/bin/env bash
set -euo pipefail

# Usage (run OUTSIDE container):
#   ./device/maleicacid/androidtv-tools/docker/build_in_docker.sh r86s_tv_virtio

PRODUCT="${1:-}"
if [[ -z "${PRODUCT}" ]]; then
  echo "Usage: $0 <r86s_tv_virtio|qemu_tv_virtio>" >&2
  exit 1
fi

WORKDIR="$(cd "$(dirname "$0")/../.." && pwd)"

docker run --rm -it \
  -v "${WORKDIR}:/workspace" \
  -w /workspace \
  openstf/docker-aosp \
  bash -lc "
    set -euo pipefail
    source build/envsetup.sh
    lunch ${PRODUCT}-userdebug
    m -j\$(nproc) otapackage
    m -j\$(nproc) espimage-install
  "
