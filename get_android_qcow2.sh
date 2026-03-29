#!/bin/bash
set -euox pipefail


cd $(dirname "$0")
SCRIPTDIR=$(dirname "$(realpath "${BASH_SOURCE:-0}")")

mkdir ./build-work || true
pushd ./build-work
repo init -u https://github.com/LineageOS/android.git -b lineage-21.0 --git-lfs

mkdir -p .repo/local_manifests/
cp -f $SCRIPTDIR/*.xml .repo/local_manifests/
repo sync -j$(nproc) -c --force-remove-dirty || true

bash -lc  "
source build/envsetup.sh
vendor/lineage/build/tools/roomservice.py lineage_virtio_x86_64_tv
"

$SCRIPTDIR/docker/build_in_docker.sh
sudo rm -f out/target/product/virtio_x86_64_tv_grub/disk-vda.qcow2 || true
sudo rm -f out/target/product/virtio_x86_64_tv_grub/userdata-empty.qcow2 || true
$SCRIPTDIR/image/make_disk_image.sh

popd
