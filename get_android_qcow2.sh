#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"
SCRIPTDIR="$(dirname "$(realpath "${BASH_SOURCE:-0}")")"

mkdir ./build-work || true
pushd ./build-work

BUILD_WORK_DIR="$(pwd -P)"
WORKSPACE_ROOT="$(dirname "${BUILD_WORK_DIR}")"

PRODUCT="${ANDROID_PRODUCT:-virtio_x86_64_tv_grub}"

PX4_DRV_GIT_URL="${PX4_DRV_GIT_URL:-https://github.com/kazuki0824/px4