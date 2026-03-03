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

# Find Android TOP by walking upwards until build/envsetup.sh exists.
TOP="$(cd "$(dirname "$0")" && pwd)"
while [[ "${TOP}" != "/" && ! -f "${TOP}/build/envsetup.sh" ]]; do
  TOP="$(dirname "${TOP}")"
done
if [[ ! -f "${TOP}/build/envsetup.sh" ]]; then
  echo "[!] Could not find Android top (build/envsetup.sh). Run from within the repo-synced tree." >&2
  exit 1
fi

docker run --rm -it \
  -v "${TOP}:/workspace" \
  -w /workspace \
  openstf/aosp:jdk8 \
  bash -lc "
    if [[ \"\${NO_AB:-0}\" == 1 ]]; then
      export AB_OTA_UPDATER=false
      echo '[build] AB_OTA_UPDATER=false (non-A/B)'
    fi

    source build/envsetup.sh
    
    #lunch | grep -E 'r86s_tv_virtio|qemu_tv_virtio'
    lunch ${PRODUCT}-${RELEASE}-userdebug

    # Installer image: espimage-install (.img).
    set -e
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
