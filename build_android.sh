#!/usr/bin/env bash
set -euo pipefail

SCRIPTDIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PRODUCT="${1:-${ANDROID_PRODUCT:-virtio_x86_64_tv_grub}}"

mkdir -p "$SCRIPTDIR/build-work"
cd "$SCRIPTDIR/build-work"
mkdir -p .repo/local_manifests/
command cp -fv "$SCRIPTDIR"/*.xml .repo/local_manifests/
repo init -u https://github.com/LineageOS/android.git -b lineage-22.1 --git-lfs
repo sync -j"$(nproc)" -c --force-remove-dirty

bash -lc '
source build/envsetup.sh
vendor/lineage/build/tools/roomservice.py lineage_virtio_x86_64_tv
'
bash "$SCRIPTDIR/patches/lineage-22.1/apply_patches.sh"
sed -i '/defaults: \["maleicacid_tuner_hal2_loom_test_defaults"\],/d' \
    vendor/maleicacid/tv/tuner_hal2/Android.bp

TUNER_AIDL_UPDATE_API=1 "$SCRIPTDIR/docker/build_in_docker.sh" "$PRODUCT"

OUT="out/target/product/$PRODUCT"
test -s "$OUT/disk-vda.img"
test -s "$OUT/persist.img"
# Reject an unmodified upstream boot disk. External state must never be
# shadowed by the legacy PERSIST/metadata partitions on vda.
sgdisk --print "$OUT/disk-vda.img" | grep -Eq 'metadata-unused$'
sgdisk --print "$OUT/disk-vda.img" | grep -Eq 'persist-unused$'
