#!/bin/bash
set -euox pipefail

cd $(dirname "$0")
SCRIPTDIR=$(dirname "$(realpath "${BASH_SOURCE:-0}")")

mkdir ./build-work || true
pushd ./build-work

BUILD_WORK_DIR="$(pwd -P)"
BUILD_WORK_PARENT="$(dirname "$BUILD_WORK_DIR")"

mkdir -p .repo/local_manifests/
command cp -fv $SCRIPTDIR/*.xml .repo/local_manifests/
repo init -u https://github.com/LineageOS/android.git -b lineage-21.0 --git-lfs
repo sync -j$(nproc) -c --force-remove-dirty || true

bash -lc  "
source build/envsetup.sh
vendor/lineage/build/tools/roomservice.py lineage_virtio_x86_64_tv
"

PRODUCT="r86s_virtio_tv"

# Build px4_drv before invoking `m`. The Android product consumes this archive
# through BOARD_VENDOR_KERNEL_MODULES_ARCHIVE.
PX4_MODULE_ARCHIVE="${BUILD_WORK_DIR}/device/maleicacid/virtio_x86_64_tv_grub/px4_drv/prebuilt/px4_drv_vendor_modules.zip"

# Keep build-work placement unchanged. Put kernel-build-only checkouts next to
# the actual build-work directory, not inside build-work.
PX4_KLEAF_ACK_DIR="${PX4_KLEAF_ACK_DIR:-${BUILD_WORK_PARENT}/px4_drv_ack}"
PX4_DDK_WS="${PX4_DDK_WS:-${BUILD_WORK_PARENT}/px4_ddk_ws}"

PX4_KLEAF_MANIFEST_URL="${PX4_KLEAF_MANIFEST_URL:-https://android.googlesource.com/kernel/manifest}"
PX4_KLEAF_MANIFEST_BRANCH="${PX4_KLEAF_MANIFEST_BRANCH:-common-android15-6.6}"
PX4_DDK_WS_GIT_URL="${PX4_DDK_WS_GIT_URL:-https://github.com/kazuki0824/px4_ddk_ws.git}"
PX4_DDK_WS_GIT_REF="${PX4_DDK_WS_GIT_REF:-main}"

PX4_DRV_SRC="${PX4_DRV_SRC:-${BUILD_WORK_DIR}/external/px4_drv}"

# Prepare ACK/Kleaf checkout as an independent repo client outside build-work.
mkdir -p "${PX4_KLEAF_ACK_DIR}"
(
  cd "${PX4_KLEAF_ACK_DIR}"

  if [ ! -d .repo ]; then
    repo init \
      -u "${PX4_KLEAF_MANIFEST_URL}" \
      -b "${PX4_KLEAF_MANIFEST_BRANCH}"
  fi

  repo sync -j"$(nproc)" -c --force-remove-dirty
)

if [ ! -x "${PX4_KLEAF_ACK_DIR}/tools/bazel" ]; then
  echo "error: ${PX4_KLEAF_ACK_DIR} is not a complete ACK/Kleaf checkout: missing tools/bazel" >&2
  exit 1
fi

if [ ! -d "${PX4_KLEAF_ACK_DIR}/build/kernel/kleaf" ]; then
  echo "error: ${PX4_KLEAF_ACK_DIR} is not a complete ACK/Kleaf checkout: missing build/kernel/kleaf" >&2
  exit 1
fi

if [ ! -d "${PX4_KLEAF_ACK_DIR}/common" ]; then
  echo "error: ${PX4_KLEAF_ACK_DIR} is not a complete ACK/Kleaf checkout: missing common/" >&2
  exit 1
fi

if [ ! -d "${PX4_DRV_SRC}" ]; then
  echo "error: px4_drv source directory not found: ${PX4_DRV_SRC}" >&2
  exit 1
fi

if [ ! -f "${PX4_DRV_SRC}/BUILD.bazel" ]; then
  echo "error: px4_drv BUILD.bazel not found: ${PX4_DRV_SRC}/BUILD.bazel" >&2
  exit 1
fi

if grep -q '@gki_prebuilts' "${PX4_DRV_SRC}/BUILD.bazel"; then
  echo "error: px4_drv BUILD.bazel still references @gki_prebuilts." >&2
  echo "       Push the ACK-root DDK BUILD.bazel to px4_drv feat/android-ddk first." >&2
  exit 1
fi

# Prepare px4 DDK helper repository next to build-work.
if [ ! -d "${PX4_DDK_WS}/.git" ]; then
  rm -rf "${PX4_DDK_WS}"
  git clone "${PX4_DDK_WS_GIT_URL}" "${PX4_DDK_WS}"
fi

(
  cd "${PX4_DDK_WS}"
  git fetch --all --tags
  git checkout "${PX4_DDK_WS_GIT_REF}"
  git pull --ff-only || true
)

rm -f "${PX4_MODULE_ARCHIVE}"
mkdir -p "$(dirname "${PX4_MODULE_ARCHIVE}")"

PX4_KLEAF_ACK_DIR="${PX4_KLEAF_ACK_DIR}" \
PX4_DRV_SRC="${PX4_DRV_SRC}" \
PX4_MODULE_ARCHIVE="${PX4_MODULE_ARCHIVE}" \
  "${PX4_DDK_WS}/scripts/build_px4_vendor_modules_zip.sh"

test -s "${PX4_MODULE_ARCHIVE}"

$SCRIPTDIR/docker/build_in_docker.sh $PRODUCT
sudo rm -f out/target/product/$PRODUCT/disk-vda.qcow2 || true
sudo rm -f out/target/product/$PRODUCT/userdata-empty.qcow2 || true
$SCRIPTDIR/image/make_disk_image.sh

popd
