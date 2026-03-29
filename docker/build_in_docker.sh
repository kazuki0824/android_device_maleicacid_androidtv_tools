#!/usr/bin/env bash
set -euo pipefail

# Build helper for the v16.2 U-Boot-first qcow2 flow.
# Run from Android build root (./.repo must exist).
#
# Outputs expected by make_selfcontained_qcow2.v16.2.sh:
#   - boot.img
#   - vendor_boot.img
#   - super.img
#   - optional vbmeta.img
#
# Usage:
#   ../android_device_maleicacid_androidtv_tools/docker/build_in_docker.v9.sh lineage_qemu_tv_virtio
#   ../android_device_maleicacid_androidtv_tools/docker/build_in_docker.v9.sh lineage_r86s_tv_virtio

PRODUCT="${1:-virtio_x86_64_tv_grub}"

[[ -d ./.repo ]] || { echo "[!] Run this script from the Android build root (./.repo must exist)." >&2; exit 1; }

TOOLS_DIR="$(cd -- "$(dirname -- "$(realpath -- "${BASH_SOURCE[0]}")")" && pwd)"

pushd "$TOOLS_DIR" >/dev/null
sudo docker build -t aosp-build .
popd >/dev/null

mkdir -p ./ccache

sudo docker run --rm -it \
  --mount "type=bind,src=$PWD/ccache,dst=/home/builder/.ccache" \
  -v "$(pwd):/workspace" \
  -w /workspace \
  aosp-build \
  bash -lc "
    source build/envsetup.sh
    breakfast ${PRODUCT}

    set -e

    # microG workaround
    rm -f vendor/maleicacid/microg/upstream/GmsCore/Android.mk || \
      sudo rm -f vendor/maleicacid/microg/upstream/GmsCore/Android.mk || true

    m -j\$(nproc) diskimage-vda ota
  "
