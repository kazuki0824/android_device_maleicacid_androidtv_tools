#!/usr/bin/env bash
set -euo pipefail

# Build helper for preinstalled qcow2 v14 flow.
#
# This flow intentionally does NOT build espimage-install, otapackage, or systemimage.
# Instead it builds the exact source ingredients needed to assemble a normal-boot
# EFI System Partition and payload disk on the host side:
#   - kernel
#   - ramdisk.img
#   - super.img
#
# Usage (outside container, from Android TOP / build-work):
#   ../android_device_maleicacid_androidtv_tools/docker/build_in_docker.v6.sh lineage_qemu_tv_virtio
#   ../android_device_maleicacid_androidtv_tools/docker/build_in_docker.v6.sh lineage_r86s_tv_virtio

PRODUCT="${1:-}"
RELEASE="ap2a"
if [[ -z "${PRODUCT}" ]]; then
  echo "Usage: $0 <lineage_r86s_tv_virtio|lineage_qemu_tv_virtio>" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE:-0}")")" && pwd)"
pushd "$SCRIPT_DIR" >/dev/null
sudo docker build -t aosp-build .
popd

mkdir -p ./ccache
sudo docker run --rm -it \
  --mount "type=bind,src=$PWD/ccache,dst=/home/builder/.ccache" \
  -v "$(pwd):/workspace" \
  -w /workspace \
  aosp-build \
  bash -lc "
    export OUT_DIR_COMMON_BASE=\${OUT_DIR_COMMON_BASE:-/workspace/out-${PRODUCT}}

    if [[ \"\${NO_AB:-0}\" == 1 ]]; then
      export AB_OTA_UPDATER=false
      echo '[build] AB_OTA_UPDATER=false (non-A/B)'
    fi

    source build/envsetup.sh
    echo ${PRODUCT}-${RELEASE}-userdebug
    lunch ${PRODUCT}-${RELEASE}-userdebug

    set -e
    rm -f vendor/maleicacid/microg/upstream/GmsCore/Android.mk || \
      sudo rm -f vendor/maleicacid/microg/upstream/GmsCore/Android.mk || true

    # Build only the ingredients required by v14.
    m -j\$(nproc) kernel ramdisk superimage

    PRODUCT_OUT=\"\$(get_build_var PRODUCT_OUT)\"
    echo '[build] Done.'
    echo \"[build] PRODUCT_OUT: \${PRODUCT_OUT}\"
    echo \"[build] Expected artifacts: \${PRODUCT_OUT}/kernel \${PRODUCT_OUT}/ramdisk.img \${PRODUCT_OUT}/super.img\"
  "
