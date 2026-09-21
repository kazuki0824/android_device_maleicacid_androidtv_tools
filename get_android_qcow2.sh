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

PATCH_RESULTS=()
PATCH_FAILURES=()

reset_patch_repo() {
    local repo="\$1"
    local label="\$2"
    if git -C "\$repo" reset --hard; then
        PATCH_RESULTS+=("RESET    \$label")
    else
        PATCH_RESULTS+=("FAILED   reset \$label")
        PATCH_FAILURES+=("reset \$label (\$repo)")
    fi
}

try_patch() {
    local repo="\$1"
    local patch="\$2"
    local label="\$3"

    if git -C "\$repo" apply --check "\$patch"; then
        if git -C "\$repo" apply "\$patch"; then
            PATCH_RESULTS+=("APPLIED  \$label")
        else
            PATCH_RESULTS+=("FAILED   \$label")
            PATCH_FAILURES+=("\$label: apply failed after apply --check succeeded")
        fi
    elif git -C "\$repo" apply --reverse --check "\$patch"; then
        PATCH_RESULTS+=("PRESENT  \$label")
    else
        PATCH_RESULTS+=("FAILED   \$label")
        PATCH_FAILURES+=("\$label: neither forward nor reverse dry-run applies")
    fi
}

# Start every invocation from the synced repository HEADs. Reset each repository
# only once so multiple patches targeting the same repository can compose.
reset_patch_repo hardware/interfaces/tv/tuner "hardware/interfaces/tv/tuner"
reset_patch_repo frameworks/base "frameworks/base"
reset_patch_repo frameworks/av "frameworks/av"

try_patch hardware/interfaces/tv/tuner \
    "\$PWD/vendor/maleicacid/tv/tuner_hal2/platform_patches/lineage-22.1/android_hardware_tv_tuner_nullable_current.patch" \
    "Tuner nullable AIDL source"

try_patch frameworks/base \
    "\$PWD/vendor/maleicacid/tv/tuner_hal2/platform_patches/lineage-22.1/android_frameworks_base_tuner_filter_null_data_source.patch" \
    "frameworks/base Tuner Filter null data source"

try_patch frameworks/av \
    "\$PWD/vendor/maleicacid/tv/tuner_hal2/platform_patches/lineage-22.1/android_frameworks_av_tuner_filter_null_data_source.patch" \
    "frameworks/av Tuner Filter null data source"

try_patch frameworks/base \
    "\"${SCRIPTDIR}/patches/lineage-22.1/frameworks_base_dropbox_early_boot_guard.patch\"" \
    "frameworks/base DropBox early-boot guard"

echo "[+] Patch phase summary:"
printf "    %s\\n" "\${PATCH_RESULTS[@]}"

if (( \${#PATCH_FAILURES[@]} > 0 )); then
    echo "[!] Patch phase failed; all patch attempts completed. Failures:" >&2
    printf "    - %s\\n" "\${PATCH_FAILURES[@]}" >&2
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
