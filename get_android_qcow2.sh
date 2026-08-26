#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"
SCRIPTDIR="$(dirname "$(realpath "${BASH_SOURCE:-0}")")"

mkdir -p ./build-work
pushd ./build-work

PRODUCT="${ANDROID_PRODUCT:-virtio_x86_64_tv_grub}"

mkdir -p .repo/local_manifests/
command cp -fv "${SCRIPTDIR}"/*.xml .repo/local_manifests/
repo init -u https://github.com/LineageOS/android.git -b lineage-22.1 --git-lfs
repo sync -j"$(nproc)" -c --force-remove-dirty --force-sync || true

bash -lc "
source build/envsetup.sh
vendor/lineage/build/tools/roomservice.py lineage_virtio_x86_64_tv

PATCH=vendor/maleicacid/tv/tuner_hal2/platform_patches/lineage-22.1/android_hardware_tv_tuner_nullable_current.patch
if git -C hardware/interfaces apply --check \"\$PWD/\$PATCH\"; then
    git -C hardware/interfaces apply \"\$PWD/\$PATCH\"
elif git -C hardware/interfaces apply --reverse --check \"\$PWD/\$PATCH\"; then
    echo '[+] Tuner nullable AIDL source patch is already applied.'
else
    echo '[!] Tuner nullable AIDL source patch does not apply cleanly.' >&2
    exit 1
fi

sed -i '/defaults: \[\"maleicacid_tuner_hal2_loom_test_defaults\"\],/d' \
    vendor/maleicacid/tv/tuner_hal2/Android.bp
"

TUNER_AIDL_UPDATE_API=1 "${SCRIPTDIR}/docker/build_in_docker.sh" "${PRODUCT}"
"${SCRIPTDIR}/image/verify_px4_in_raw.sh" "${PRODUCT}"
sudo rm -f "out/target/product/${PRODUCT}/disk-vda.qcow2" || true
sudo rm -f "out/target/product/${PRODUCT}/userdata-empty.qcow2" || true
"${SCRIPTDIR}/image/make_disk_image.sh" \
  --product-out "out/target/product/${PRODUCT}"

popd
