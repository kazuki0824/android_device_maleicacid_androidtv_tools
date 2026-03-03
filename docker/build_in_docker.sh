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
if [[ -z "${PRODUCT}" ]]; then
  echo "Usage: $0 <r86s_tv_virtio|qemu_tv_virtio>" >&2
  exit 1
fi

TOP="$(cd "$(dirname "$0")/../.." && pwd)"

docker run --rm -it \
  -v "${TOP}:/workspace" \
  -w /workspace \
  openstf/docker-aosp \
  bash -lc "
    set -euo pipefail
    if [[ \"\${NO_AB:-0}\" == 1 ]]; then
      export AB_OTA_UPDATER=false
      echo '[build] AB_OTA_UPDATER=false (non-A/B)'
    fi

    source build/envsetup.sh
    lunch ${PRODUCT}-userdebug

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
