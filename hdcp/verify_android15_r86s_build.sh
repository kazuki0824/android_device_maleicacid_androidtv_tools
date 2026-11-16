#!/usr/bin/env bash
# Real Android 15 build gate for temporary PR #22. Do NOT run on the stock
# small GitHub-hosted runner: requires a fully synced/prepared LineageOS tree.
set -eo pipefail
if (( $# != 1 )); then
  echo "Usage: bash hdcp/verify_android15_r86s_build.sh /path/to/prepared-LineageOS-22.1-tree" >&2
  exit 2
fi
root="$(realpath "$1")"
if [[ ! -d "$root/.repo" || ! -f "$root/build/envsetup.sh" ]]; then
  echo "An already synced Android source tree is required" >&2
  exit 2
fi
cd "$root"
device="device/maleicacid/virtio_x86_64_tv_grub"
widevine="vendor/google/proprietary/widevine-prebuilt"
test "$(git -C "$device" rev-parse HEAD)" = "72bb65594e7bfa185d64be303dd14f834f334c8b" || {
  echo "Wrong device PR #10 SHA; apply temporary overlay manifest" >&2; exit 3;
}
# Product manifest deliberately follows the celadon branch, not a SHA.
# The static ELF audit uses a historical snapshot independently.
test -d "$widevine/.git" || {
  echo "Widevine source checkout is missing" >&2; exit 3;
}
echo "Widevine product checkout SHA: $(git -C "$widevine" rev-parse HEAD)"
jobs=4
logdir="$root/out/hdcp-validation"
mkdir -p "$logdir"
# Source against a prepared tree with all required platform patches applied.
# Do not run cleanup, reset, repo sync, or proprietary binaries here.
set +u
source build/envsetup.sh
type breakfast >/dev/null 2>&1 || { echo "LineageOS breakfast missing" >&2; exit 3; }
breakfast lineage_r86s_virtio_tv-maleicacid_tv_unfrozen-userdebug \
  2>&1 | tee "$logdir/00-breakfast.log"
# Compile the actual HWC3 service incorporating the product HDCP patch,
# not only the separate Widevine HAL.
m -j4 android.hardware.composer.hwc3-service.drm.virtio_x86_64 \
  2>&1 | tee "$logdir/01-hwc3-soong.log"
m -j4 android.hardware.drm-service.widevine \
  2>&1 | tee "$logdir/02-widevine-soong.log"
m -j4 vendor_sepolicy.cil \
  2>&1 | tee "$logdir/03-vendor-sepolicy.log"
m -j4 check-vintf-all \
  2>&1 | tee "$logdir/04-vintf.log"
# Separate build correctness from installation, which is target-dependent.
echo "PASS: targeted Soong, vendor SELinux and VINTF build targets."
echo "NOT PROVEN: fully flashed/installed image, L3 provisioning or HDMI HDCP."
