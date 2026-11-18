#!/usr/bin/env bash
# Real Android 15 build gate for temporary PR #22. Do NOT run on the stock
# small GitHub-hosted runner: requires a fully synced/prepared LineageOS tree.
set -eo pipefail
if (( $# != 1 )); then
  echo "Usage: bash hdcp/verify_android15_r86s_build.sh /path/to/prepared-LineageOS-22.1-tree" >&2
  exit 2
fi
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
root="$(realpath "$1")"
if [[ ! -d "$root/.repo" || ! -f "$root/build/envsetup.sh" ]]; then
  echo "An already synced Android source tree is required" >&2
  exit 2
fi
cd "$root"
device="device/maleicacid/virtio_x86_64_tv_grub"
widevine="vendor/google/proprietary/widevine-prebuilt"
test "$(git -C "$device" rev-parse HEAD)" = "2b152fd5242075b9ca7730b2256eb7eb5aff1554" || {
  echo "Wrong device PR #10 SHA; apply temporary overlay manifest" >&2; exit 3;
}
# Product manifest deliberately follows the celadon branch, not a SHA.
# The static ELF audit uses a historical snapshot independently.
git -C "$widevine" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  echo "Widevine source checkout is missing" >&2; exit 3;
}
echo "Widevine product checkout SHA: $(git -C "$widevine" rev-parse HEAD)"
echo "HDCP evidence: this script NEVER claims successful runtime playback."
# Capture the exact synced manifest and implementation state before compiling.
mkdir -p out/hdcp-validation
repo manifest -r -o out/hdcp-validation/manifest-revisions.xml
git -C "$device" rev-parse HEAD > out/hdcp-validation/device-sha.txt
git -C "$widevine" rev-parse HEAD > out/hdcp-validation/widevine-sha.txt
if [[ ! -f external/drm_hwcomposer/drm/DrmAtomicStateManager.cpp ]]; then
  echo "Missing external/drm_hwcomposer source" >&2
  exit 3
fi
hwc_source="external/drm_hwcomposer/drm/DrmAtomicStateManager.cpp"
for token in 'drmModeAtomicDuplicate(pset.get())' '"Content Protection"' '"Desired"' 'HDCP Enabled'; do
  if ! grep -Fq "$token" "$hwc_source"; then
    echo "Product #15 HDCP atomic patch not applied: missing $token" >&2
    exit 3
  fi
done
git -C external/drm_hwcomposer rev-parse HEAD > out/hdcp-validation/hwc-source-sha.txt
git -C external/drm_hwcomposer diff -- drm/DrmAtomicStateManager.cpp > out/hdcp-validation/hwc-local-diff.txt || true
for name in android.hardware.drm-service.widevine libwvaidl.so; do
  f="$widevine/$name"
  test -f "$f" || { echo "Missing Widevine prebuilt binary: $f" >&2; exit 3; }
  sha256sum "$f" >> out/hdcp-validation/prebuilt-hashes.sha256
done
# Obtain the product patch from the actual branch HEAD and prove that the
# checked-out HWC tree contains that exact patch (fail closed on stale source).
tools_head="$(bash "$script_dir/verify_product_patch_provenance.sh" \
  "https://github.com/kazuki0824/android_device_maleicacid_androidtv_tools.git" \
  "refs/heads/feature/r86s-hdcp-over-pr12" \
  "$root/external/drm_hwcomposer" \
  "$root/out/hdcp-validation")"
printf '%s\n' \
  "Production tools PR #15 patch revision (verified): $tools_head" \
  "Device PR #10: $(git -C "$device" rev-parse HEAD)" \
  "Widevine celadon checkout: $(git -C "$widevine" rev-parse HEAD)" \
  "Kernel source: $(git -C kernel/virt/virtio rev-parse HEAD 2>/dev/null || echo unavailable)" \
  > out/hdcp-validation/validation-provenance.txt
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
# Separate input prebuilts, installed files and final image contents.
# Soong target success does not imply an updated vendor image.
product_out="out/target/product/r86s_virtio_tv"
install_dir="$product_out/vendor"
installed_report="$logdir/installed-vendor-binaries.sha256"
image_report="$logdir/final-vendor-image-evidence.txt"
: > "$installed_report"
: > "$image_report"
for entry in "bin/hw/android.hardware.drm-service.widevine" "lib64/libwvaidl.so"; do
  installed="$install_dir/$entry"
  if [[ -f "$installed" ]]; then
    sha256sum "$installed" >> "$installed_report"
  else
    printf 'UNVERIFIED: installed file absent: %s\n' "$installed" | tee -a "$image_report"
  fi
done
if [[ -f "$product_out/vendor.img" ]]; then
  printf 'Final vendor image present: %s\n' "$product_out/vendor.img" >> "$image_report"
  sha256sum "$product_out/vendor.img" >> "$image_report"
  # A whole-image hash alone does NOT prove that the two named files exist
  # inside it. Extract/inspect filesystem contents separately.
  printf 'UNVERIFIED: image member contents not inspected; vendor.img hash is not per-file evidence\n' >> "$image_report"
else
  printf 'UNVERIFIED: final vendor.img was not built by these targeted Soong jobs\n' >> "$image_report"
fi
echo "PASS: targeted Soong, vendor SELinux and VINTF build targets."
echo "UNVERIFIED: final vendor image member contents, L3 provisioning and HDMI HDCP."
