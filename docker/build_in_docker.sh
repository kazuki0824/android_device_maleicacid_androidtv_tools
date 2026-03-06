#!/usr/bin/env bash
set -euo pipefail

# Build helper for requirement 11/13:
# - Source sync: outside container (repo sync already done)
# - Build: inside openstf/docker-aosp container
#
# Usage (outside container, from ANDROID TOP):
#   device/maleicacid/androidtv-tools/docker/build_in_docker.sh r86s_tv_virtio
#   device/maleicacid/androidtv-tools/docker/build_in_docker.sh qemu_tv_virtio
#
# Optional:
#   NO_AB=1 ... build non-A/B images (smaller disk footprint)

PRODUCT="${1:-}"
RELEASE=ap2a
if [[ -z "${PRODUCT}" ]]; then
  echo "Usage: $0 <r86s_tv_virtio|qemu_tv_virtio>" >&2
  exit 1
fi

pushd $(dirname "$(realpath "${BASH_SOURCE:-0}")")
sudo docker build -t aosp-build .
popd
sudo docker run --rm -it \
  -v "$PWD/ccache:/home/builder/.ccache" \
  -v "$(pwd):/workspace" \
  -w /workspace \
  aosp-build \
  bash -lc "
    if [[ \"\${NO_AB:-0}\" == 1 ]]; then
      export AB_OTA_UPDATER=false
      echo '[build] AB_OTA_UPDATER=false (non-A/B)'
    fi

    source build/envsetup.sh
    
    #lunch | grep -E 'r86s_tv_virtio|qemu_tv_virtio'
    echo ${PRODUCT}-${RELEASE}-userdebug
    lunch lineage_virtio_x86_64_tv-ap2a-userdebug
    #lunch ${PRODUCT}-${RELEASE}-userdebug

    set -e
    # microG workaround
    rm -f vendor/maleicacid/microg/upstream/GmsCore/Android.mk || sudo rm -f vendor/maleicacid/microg/upstream/GmsCore/Android.mk || true
    # Installer image: espimage-install (.img).
    m -j\$(nproc) espimage-install

    # Flashable zip to apply in recovery.
    # If otapackage is missing, bacon usually produces the flashable zip.
    if m -j\$(nproc) otapackage; then
      echo '[build] Built otapackage'
    else
      echo '[build] otapackage not available; falling back to bacon'
      m -j\$(nproc) bacon
    fi

    echo '[build] Done.'
    echo \"[build] Outputs in: out/target/product/${PRODUCT}\"
  "
