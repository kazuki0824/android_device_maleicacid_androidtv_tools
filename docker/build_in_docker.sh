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

PRODUCT="${1:-}"
RELEASE="ap2a"
VARIANT="userdebug"

if [[ -z "$PRODUCT" ]]; then
  echo "Usage: $0 <lineage_qemu_tv_virtio|lineage_r86s_tv_virtio>" >&2
  exit 1
fi

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
    export OUT_DIR_COMMON_BASE=\${OUT_DIR_COMMON_BASE:-/workspace/out-${PRODUCT}}

    source build/envsetup.sh
    lunch ${PRODUCT}-${RELEASE}-${VARIANT}

    set -e

    # microG workaround
    rm -f vendor/maleicacid/microg/upstream/GmsCore/Android.mk || \
      sudo rm -f vendor/maleicacid/microg/upstream/GmsCore/Android.mk || true

    m -j\$(nproc) bootimage vendorbootimage superimage

    PRODUCT_OUT=\"\$(get_build_var PRODUCT_OUT)\"
    echo '[build] Done.'
    echo \"[build] PRODUCT_OUT: \${PRODUCT_OUT}\"
    echo \"[build] Expected artifacts: \${PRODUCT_OUT}/boot.img \${PRODUCT_OUT}/vendor_boot.img \${PRODUCT_OUT}/super.img\"
    if [[ -f \"\${PRODUCT_OUT}/vbmeta.img\" ]]; then
      echo \"[build] Optional artifact present: \${PRODUCT_OUT}/vbmeta.img\"
    else
      echo '[build] vbmeta.img not present; qcow2 script will generate disabled vbmeta if needed.'
    fi
  "
