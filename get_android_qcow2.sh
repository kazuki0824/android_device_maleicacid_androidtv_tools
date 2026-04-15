#!/bin/bash
set -euox pipefail


cd $(dirname "$0")
SCRIPTDIR=$(dirname "$(realpath "${BASH_SOURCE:-0}")")

mkdir ./build-work || true
pushd ./build-work

mkdir -p .repo/local_manifests/
command cp -fv $SCRIPTDIR/*.xml .repo/local_manifests/
repo init -u https://github.com/LineageOS/android.git -b lineage-21.0 --git-lfs
repo sync -j$(nproc) -c --force-remove-dirty || true

bash -lc  "
source build/envsetup.sh
vendor/lineage/build/tools/roomservice.py lineage_virtio_x86_64_tv
"

PRODUCT="r86s_virtio_tv"

$SCRIPTDIR/docker/build_in_docker.sh $PRODUCT
sudo rm -f out/target/product/$PRODUCT/disk-vda.qcow2 || true
sudo rm -f out/target/product/$PRODUCT/userdata-empty.qcow2 || true
$SCRIPTDIR/image/make_disk_image.sh

popd
