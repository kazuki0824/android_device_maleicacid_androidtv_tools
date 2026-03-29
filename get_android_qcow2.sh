#!/bin/bash
set -euox pipefail


cd $(dirname "$0")
SCRIPTDIR=$(dirname "$(realpath "${BASH_SOURCE:-0}")")

mkdir ./build-work || true
pushd ./build-work
repo init -u https://github.com/LineageOS/android.git -b lineage-21.0 --git-lfs #--no-clone-bundle

mkdir -p .repo/local_manifests/
cp -f $SCRIPTDIR/*.xml .repo/local_manifests/
repo sync -j$(nproc) -c -d --force-remove-dirty || true

bash -lc  "
source build/envsetup.sh
vendor/lineage/build/tools/roomservice.py lineage_virtio_x86_64_tv
"

$SCRIPTDIR/docker/build_in_docker.sh
$SCRIPTDIR/image/make_disk_image.sh

popd
