#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"
SCRIPTDIR="$(dirname "$(realpath "${BASH_SOURCE:-0}")")"

mkdir ./build-work || true
pushd ./build-work

BUILD_WORK_DIR="$(pwd -P)"
WORKSPACE_ROOT="$(dirname "${BUILD_WORK_DIR}")"

PRODUCT="r86s_virtio_tv"

PX4_DRV_GIT_URL="${PX4_DRV_GIT_URL:-https://github.com/kazuki0824/px4_drv.git}"
PX4_DRV_GIT_REF="${PX4_DRV_GIT_REF:-feat/android-ddk}"

PX4_KLEAF_MANIFEST_URL="${PX4_KLEAF_MANIFEST_URL:-https://android.googlesource.com/kernel/manifest}"
PX4_KLEAF_MANIFEST_BRANCH="${PX4_KLEAF_MANIFEST_BRANCH:-common-android15-6.6}"

sync_px4_drv_source() {
  local px4_drv_src="${WORKSPACE_ROOT}/px4_drv"

  if [ -d "${px4_drv_src}/.git" ]; then
    (
      cd "${px4_drv_src}"
      git fetch --all --tags
      git checkout "${PX4_DRV_GIT_REF}"
      git pull --ff-only || true
    )
  elif [ -d "${px4_drv_src}" ]; then
    echo "Using existing non-git px4_drv source tree: ${px4_drv_src}"
  else
    git clone "${PX4_DRV_GIT_URL}" "${px4_drv_src}"
    (
      cd "${px4_drv_src}"
      git checkout "${PX4_DRV_GIT_REF}"
      git pull --ff-only || true
    )
  fi

  for required in BUILD.bazel Kbuild Makefile; do
    if [ ! -f "${px4_drv_src}/${required}" ]; then
      echo "error: px4_drv source tree is missing ${required}: ${px4_drv_src}/${required}" >&2
      echo "       PX4_DRV_GIT_REF must point to the Kleaf-minimal px4_drv layout." >&2
      exit 1
    fi
  done

  if [ -f "${px4_drv_src}/driver/BUILD.bazel" ]; then
    echo "error: driver/BUILD.bazel must not exist for the top-level Kleaf module layout." >&2
    echo "       PX4_DRV_GIT_REF must point to the Kleaf-minimal px4_drv layout." >&2
    exit 1
  fi
}

sync_px4_ack_checkout() {
  local px4_kleaf_ack_dir="${WORKSPACE_ROOT}/px4_drv_ack"

  mkdir -p "${px4_kleaf_ack_dir}"

  (
    cd "${px4_kleaf_ack_dir}"

    if [ ! -d .repo ]; then
      repo init \
        -u "${PX4_KLEAF_MANIFEST_URL}" \
        -b "${PX4_KLEAF_MANIFEST_BRANCH}"
    fi

    repo sync -j"$(nproc)" -c --force-remove-dirty
  )

  if [ ! -x "${px4_kleaf_ack_dir}/tools/bazel" ]; then
    echo "error: ACK/Kleaf checkout is missing executable tools/bazel: ${px4_kleaf_ack_dir}" >&2
    exit 1
  fi

  if [ ! -d "${px4_kleaf_ack_dir}/build/kernel/kleaf" ]; then
    echo "error: ACK/Kleaf checkout is missing build/kernel/kleaf: ${px4_kleaf_ack_dir}" >&2
    exit 1
  fi

  if [ ! -d "${px4_kleaf_ack_dir}/common" ]; then
    echo "error: ACK/Kleaf checkout is missing common/: ${px4_kleaf_ack_dir}" >&2
    exit 1
  fi
}

build_px4_vendor_modules_zip() {
  local px4_kleaf_ack_dir="${WORKSPACE_ROOT}/px4_drv_ack"
  local px4_drv_src="${WORKSPACE_ROOT}/px4_drv"

  local device_tree_dir="${BUILD_WORK_DIR}/device/maleicacid/virtio_x86_64_tv_grub"
  local px4_module_archive="${device_tree_dir}/px4_drv/prebuilt/px4_drv_vendor_modules.zip"

  local px4_gen_dir="${BUILD_WORK_DIR}/out/px4_drv_prebuild"
  local px4_work="${px4_gen_dir}/px4_drv"
  local px4_staging="${px4_gen_dir}/staging"

  local px4_stage_dir="${px4_kleaf_ack_dir}/local_modules/px4_drv"
  local px4_bazel_target="//local_modules/px4_drv:px4_drv"
  local px4_built_ko="${px4_kleaf_ack_dir}/bazel-bin/local_modules/px4_drv/px4_drv/px4_drv.ko"

  if [ ! -d "${device_tree_dir}" ]; then
    echo "error: device tree is missing: ${device_tree_dir}" >&2
    echo "       This directory must be supplied by repo sync/local manifest, not created by this script." >&2
    exit 1
  fi

  if [ ! -d "${px4_drv_src}" ]; then
    echo "error: px4_drv source tree not found: ${px4_drv_src}" >&2
    exit 1
  fi

  for required in BUILD.bazel Kbuild Makefile; do
    if [ ! -f "${px4_drv_src}/${required}" ]; then
      echo "error: px4_drv source tree is missing ${required}: ${px4_drv_src}/${required}" >&2
      exit 1
    fi
  done

  if [ -f "${px4_drv_src}/driver/BUILD.bazel" ]; then
    echo "error: driver/BUILD.bazel must not exist for the top-level Kleaf module layout." >&2
    exit 1
  fi

  if grep -R -q '@gki_prebuilts' "${px4_drv_src}/BUILD.bazel" "${px4_drv_src}/Kbuild" "${px4_drv_src}/Makefile"; then
    echo "error: px4_drv build files still reference @gki_prebuilts." >&2
    exit 1
  fi

  rm -rf "${px4_gen_dir}"
  rm -f "${px4_module_archive}"
  mkdir -p "${px4_gen_dir}" "${px4_staging}" "$(dirname "${px4_module_archive}")"

  cp -a "${px4_drv_src}" "${px4_work}"

  if [ -e "${px4_stage_dir}" ] && [ ! -f "${px4_stage_dir}/.maleicacid_px4_ddk_generated" ]; then
    echo "error: refusing to overwrite existing non-generated ACK module dir: ${px4_stage_dir}" >&2
    echo "       Remove it manually if it is safe." >&2
    exit 1
  fi

  rm -rf "${px4_stage_dir}"
  mkdir -p "$(dirname "${px4_stage_dir}")"
  cp -a "${px4_work}" "${px4_stage_dir}"
  touch "${px4_stage_dir}/.maleicacid_px4_ddk_generated"

  echo "Building ${px4_bazel_target}"
  (
    cd "${px4_kleaf_ack_dir}"
    tools/bazel build "${px4_bazel_target}"
  )

  if [ ! -f "${px4_built_ko}" ]; then
    echo "warning: expected module not found: ${px4_built_ko}" >&2
    echo "         falling back to search under bazel-bin/local_modules/px4_drv" >&2
    px4_built_ko="$(find "${px4_kleaf_ack_dir}/bazel-bin/local_modules/px4_drv" -type f -name 'px4_drv.ko' | head -n 1 || true)"
  fi

  if [ -z "${px4_built_ko}" ] || [ ! -f "${px4_built_ko}" ]; then
    echo "error: built module not found under ${px4_kleaf_ack_dir}/bazel-bin/local_modules/px4_drv" >&2
    exit 1
  fi

  echo "Using built module: ${px4_built_ko}"
  cp -f "${px4_built_ko}" "${px4_staging}/px4_drv.ko"

  (
    cd "${px4_staging}"
    zip -qry "${px4_module_archive}" .
  )

  test -s "${px4_module_archive}"
  unzip -l "${px4_module_archive}"
}

mkdir -p .repo/local_manifests/
command cp -fv "${SCRIPTDIR}"/*.xml .repo/local_manifests/
repo init -u https://github.com/LineageOS/android.git -b lineage-21.0 --git-lfs
repo sync -j"$(nproc)" -c --force-remove-dirty || true

bash -lc "
source build/envsetup.sh
vendor/lineage/build/tools/roomservice.py lineage_virtio_x86_64_tv
"

sync_px4_drv_source
sync_px4_ack_checkout
build_px4_vendor_modules_zip

"${SCRIPTDIR}/docker/build_in_docker.sh" "${PRODUCT}"
sudo rm -f "out/target/product/${PRODUCT}/disk-vda.qcow2" || true
sudo rm -f "out/target/product/${PRODUCT}/userdata-empty.qcow2" || true
"${SCRIPTDIR}/image/make_disk_image.sh"

popd
