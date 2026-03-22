#!/usr/bin/env bash
set -euo pipefail

# Build an Android TV qcow2 for virtio x86_64 together with a Google-style
# U-Boot ROM bootloader artifact.
#
# This file updates the previous GBL-first experiment into a new U-Boot ROM path.
# It intentionally removes all GBL-specific source checkout/build/staging logic and
# instead follows the public Cuttlefish/U-Boot mainline build entry for x86_64.
#
# Public sources used for this design:
#   * source.android.com/docs/devices/cuttlefish/bootloader-dev
#   * platform/external/u-boot BUILD.bazel / build.config.qemu.x86_64
#
# Run from Android build root (./.repo must exist).
#
# Usage:
#   sudo ../android_device_maleicacid_androidtv_tools/image/make_selfcontained_qcow2.sh lineage_qemu_tv_virtio
#
# Optional:
#   --system-size 16
#   --userdata-size 16
#   --release ap2a
#   --variant userdebug

PRODUCT="${1:-}"
shift || true
[[ -n "$PRODUCT" ]] || { echo "Usage: $0 <product> [options]" >&2; exit 1; }

RELEASE="ap2a"
VARIANT="userdebug"
SYSTEM_SIZE_GIB=16
USERDATA_SIZE_GIB=16

while [[ $# -gt 0 ]]; do
  case "$1" in
    --release) RELEASE="$2"; shift 2 ;;
    --variant) VARIANT="$2"; shift 2 ;;
    --system-size) SYSTEM_SIZE_GIB="$2"; shift 2 ;;
    --userdata-size) USERDATA_SIZE_GIB="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

[[ -d ./.repo ]] || { echo "[!] Run this script from the Android build root (./.repo must exist)." >&2; exit 1; }

require_host_tool() {
  local name="$1"
  local path
  path="$(command -v "$name" || true)"
  [[ -n "$path" ]] || { echo "[!] Required host tool not found in PATH: $name" >&2; exit 1; }
  printf '%s\n' "$path"
}

SGDISK_BIN="$(require_host_tool sgdisk)"
PARTPROBE_BIN="$(require_host_tool partprobe)"
MKFS_EXT4_BIN="$(require_host_tool mkfs.ext4)"
QEMU_IMG_BIN="$(require_host_tool qemu-img)"
QEMU_NBD_BIN="$(require_host_tool qemu-nbd)"
MODPROBE_BIN="$(command -v modprobe || true)"
REPO_BIN="$(require_host_tool repo)"
PYTHON3_BIN="$(require_host_tool python3)"

TOP="$(pwd -P)"
SHORT_PRODUCT="$PRODUCT"
[[ "$SHORT_PRODUCT" == lineage_* ]] && SHORT_PRODUCT="${SHORT_PRODUCT#lineage_}"

set +u
source "$TOP/build/envsetup.sh" >/dev/null
lunch "${PRODUCT}-${RELEASE}-${VARIANT}" >/dev/null
set -u

discover_product_out() {
  local base cand
  for base in \
    "$TOP/out-${PRODUCT}/workspace/target/product" \
    "$TOP/out-${PRODUCT}/target/product" \
    "$TOP/out-${SHORT_PRODUCT}/workspace/target/product" \
    "$TOP/out-${SHORT_PRODUCT}/target/product" \
    "$TOP/out/target/product"; do
    [[ -d "$base" ]] || continue
    for cand in "$base"/*; do
      [[ -d "$cand" ]] || continue
      if [[ -f "$cand/boot.img" && -f "$cand/vendor_boot.img" && -f "$cand/super.img" ]]; then
        echo "$cand"
        return 0
      fi
    done
  done
  return 1
}

PRODUCT_OUT="$(discover_product_out)" || {
  echo "[!] Could not locate PRODUCT_OUT from built artifacts." >&2
  exit 1
}
HOST_ROOT="${PRODUCT_OUT%/target/product/*}"
HOST_OUT_EXECUTABLES="$HOST_ROOT/host/linux-x86/bin"

BOOT_IMG="$PRODUCT_OUT/boot.img"
VENDOR_BOOT_IMG="$PRODUCT_OUT/vendor_boot.img"
SUPER_IMG="$PRODUCT_OUT/super.img"
PERSIST_IMG="$PRODUCT_OUT/persist.img"
VBMETA_IMG="$PRODUCT_OUT/vbmeta.img"
AVBTOOL="$HOST_OUT_EXECUTABLES/avbtool"
SIMG2IMG="$HOST_OUT_EXECUTABLES/simg2img"

for f in "$BOOT_IMG" "$VENDOR_BOOT_IMG" "$SUPER_IMG" "$AVBTOOL" "$SIMG2IMG"; do
  [[ -e "$f" ]] || { echo "[!] Required input not found: $f" >&2; exit 1; }
done

OUTPUT_DIR="$PRODUCT_OUT/preinstalled"
mkdir -p "$OUTPUT_DIR"

TOP_PARENT="$(dirname "$TOP")"
UBOOT_WORK_DIR="${TOP_PARENT}/$(basename "$TOP")-u-boot-mainline-src"
UBOOT_ROM=""
RUN_AS_USER=()
if [[ ${EUID:-$(id -u)} -eq 0 && -n "${SUDO_USER:-}" ]]; then
  ORIG_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
  [[ -n "$ORIG_HOME" ]] || ORIG_HOME="/home/$SUDO_USER"
  RUN_AS_USER=(sudo -u "$SUDO_USER" env HOME="$ORIG_HOME")
fi

run_user() {
  if [[ ${#RUN_AS_USER[@]} -gt 0 ]]; then
    "${RUN_AS_USER[@]}" "$@"
  else
    "$@"
  fi
}

build_uboot_qemu_x86_64_rom() {
  run_user mkdir -p "$UBOOT_WORK_DIR"

  if [[ ! -d "$UBOOT_WORK_DIR/.repo" ]]; then
    echo "[*] Initializing U-Boot source tree at $UBOOT_WORK_DIR"
    (
      cd "$UBOOT_WORK_DIR"
      run_user "$REPO_BIN" init -u https://android.googlesource.com/kernel/manifest -b u-boot-mainline
    )
  fi

  echo "[*] Syncing U-Boot source tree..."
  (
    cd "$UBOOT_WORK_DIR"
    run_user "$REPO_BIN" sync -j"$(nproc)" -q
  )

  [[ -x "$UBOOT_WORK_DIR/tools/bazel" ]] || {
    echo "[!] U-Boot source tree does not provide tools/bazel after repo sync:" >&2
    echo "    $UBOOT_WORK_DIR/tools/bazel" >&2
    exit 1
  }

  echo "[*] Building U-Boot ROM via tools/bazel for qemu_x86_64..."
  (
    cd "$UBOOT_WORK_DIR"
    run_user ./tools/bazel run //u-boot:qemu_x86_64_dist
  )

  UBOOT_ROM="$UBOOT_WORK_DIR/out/u-boot/dist/u-boot.rom"
  [[ -f "$UBOOT_ROM" ]] || {
    echo "[!] Expected U-Boot ROM not found: $UBOOT_ROM" >&2
    echo "[!] Installed files under $UBOOT_WORK_DIR/out/u-boot/dist:" >&2
    find "$UBOOT_WORK_DIR/out/u-boot/dist" -maxdepth 2 -type f 2>/dev/null | sort >&2 || true
    exit 1
  }
}

if [[ ! -f "$VBMETA_IMG" ]]; then
  echo "[*] Creating disabled vbmeta.img at $VBMETA_IMG"
  "$AVBTOOL" make_vbmeta_image --flag 2 --padding_size 4096 --output "$VBMETA_IMG"
fi

TMPDIR="$(mktemp -d)"
NBD_DEV=""
cleanup() {
  set +e
  sync
  [[ -n "$NBD_DEV" ]] && "$QEMU_NBD_BIN" --disconnect "$NBD_DEV" >/dev/null 2>&1 || true
  rm -rf "$TMPDIR"
}
trap cleanup EXIT

ceil_mib() {
  local bytes="$1"
  echo $(( (bytes + 1024*1024 - 1) / (1024*1024) ))
}

SUPER_RAW="$TMPDIR/super.raw"
python3 - "$SUPER_IMG" "$SUPER_RAW" "$SIMG2IMG" <<'PY'
import struct, sys, shutil, subprocess
src, dst, simg2img = sys.argv[1:4]
with open(src, 'rb') as f:
    magic = struct.unpack('<I', f.read(4))[0]
if magic == 0xed26ff3a:
    subprocess.check_call([simg2img, src, dst])
else:
    shutil.copyfile(src, dst)
PY

BOOT_MIB="$(ceil_mib "$(stat -c '%s' "$BOOT_IMG")")"
VENDOR_BOOT_MIB="$(ceil_mib "$(stat -c '%s' "$VENDOR_BOOT_IMG")")"
SUPER_MIB="$(ceil_mib "$(stat -c '%s' "$SUPER_RAW")")"
VBMETA_MIB="$(ceil_mib "$(stat -c '%s' "$VBMETA_IMG")")"
PERSIST_MIB=32
if [[ -f "$PERSIST_IMG" ]]; then
  PERSIST_MIB="$(ceil_mib "$(stat -c '%s' "$PERSIST_IMG")")"
fi
MISC_MIB=16
METADATA_MIB=64

SYSTEM_RAW="$OUTPUT_DIR/androidtv-${PRODUCT}.raw"
SYSTEM_QCOW="$OUTPUT_DIR/androidtv-${PRODUCT}.qcow2"
USERDATA_QCOW="$OUTPUT_DIR/androidtv-${PRODUCT}-userdata.qcow2"
UBOOT_ROM_OUT="$OUTPUT_DIR/u-boot.rom"

build_uboot_qemu_x86_64_rom

rm -f "$SYSTEM_RAW" "$SYSTEM_QCOW" "$USERDATA_QCOW" "$UBOOT_ROM_OUT"
cp "$UBOOT_ROM" "$UBOOT_ROM_OUT"

"$QEMU_IMG_BIN" create -f raw "$SYSTEM_RAW" "${SYSTEM_SIZE_GIB}G" >/dev/null
[[ -n "$MODPROBE_BIN" ]] && "$MODPROBE_BIN" nbd max_part=32 >/dev/null 2>&1 || true
NBD_DEV=/dev/nbd0
"$QEMU_NBD_BIN" --disconnect "$NBD_DEV" >/dev/null 2>&1 || true
"$QEMU_NBD_BIN" --format=raw --connect "$NBD_DEV" "$SYSTEM_RAW"
"$PARTPROBE_BIN" "$NBD_DEV" || true
sleep 1

"$SGDISK_BIN" --clear "$NBD_DEV"
"$SGDISK_BIN" --new=1:0:+${MISC_MIB}M         --typecode=1:8300 --change-name=1:misc          "$NBD_DEV"
"$SGDISK_BIN" --new=2:0:+${BOOT_MIB}M         --typecode=2:8300 --change-name=2:boot_a        "$NBD_DEV"
"$SGDISK_BIN" --new=3:0:+${BOOT_MIB}M         --typecode=3:8300 --change-name=3:boot_b        "$NBD_DEV"
"$SGDISK_BIN" --new=4:0:+${VENDOR_BOOT_MIB}M  --typecode=4:8300 --change-name=4:vendor_boot_a "$NBD_DEV"
"$SGDISK_BIN" --new=5:0:+${VENDOR_BOOT_MIB}M  --typecode=5:8300 --change-name=5:vendor_boot_b "$NBD_DEV"
"$SGDISK_BIN" --new=6:0:+${VBMETA_MIB}M       --typecode=6:8300 --change-name=6:vbmeta_a      "$NBD_DEV"
"$SGDISK_BIN" --new=7:0:+${VBMETA_MIB}M       --typecode=7:8300 --change-name=7:vbmeta_b      "$NBD_DEV"
"$SGDISK_BIN" --new=8:0:+${SUPER_MIB}M        --typecode=8:8300 --change-name=8:super         "$NBD_DEV"
"$SGDISK_BIN" --new=9:0:+${METADATA_MIB}M     --typecode=9:8300 --change-name=9:metadata      "$NBD_DEV"
"$SGDISK_BIN" --new=10:0:+${PERSIST_MIB}M     --typecode=10:8300 --change-name=10:persist     "$NBD_DEV"
"$PARTPROBE_BIN" "$NBD_DEV" || true
sleep 1

# Write Android payload partitions.
dd if=/dev/zero of="${NBD_DEV}p1" bs=1M count="$MISC_MIB" conv=fsync,notrunc status=none
if [[ -f "$PERSIST_IMG" ]]; then
  dd if="$PERSIST_IMG" of="${NBD_DEV}p10" bs=4M conv=fsync,notrunc status=progress
else
  "$MKFS_EXT4_BIN" -F -L persist "${NBD_DEV}p10" >/dev/null 2>&1 || true
fi
"$MKFS_EXT4_BIN" -F -L metadata "${NBD_DEV}p9" >/dev/null 2>&1 || true

dd if="$BOOT_IMG"        of="${NBD_DEV}p2" bs=4M conv=fsync,notrunc status=progress
dd if="$BOOT_IMG"        of="${NBD_DEV}p3" bs=4M conv=fsync,notrunc status=progress
dd if="$VENDOR_BOOT_IMG" of="${NBD_DEV}p4" bs=4M conv=fsync,notrunc status=progress
dd if="$VENDOR_BOOT_IMG" of="${NBD_DEV}p5" bs=4M conv=fsync,notrunc status=progress
dd if="$VBMETA_IMG"      of="${NBD_DEV}p6" bs=4M conv=fsync,notrunc status=progress
dd if="$VBMETA_IMG"      of="${NBD_DEV}p7" bs=4M conv=fsync,notrunc status=progress
dd if="$SUPER_RAW"       of="${NBD_DEV}p8" bs=4M conv=fsync,notrunc status=progress

sync
"$QEMU_NBD_BIN" --disconnect "$NBD_DEV"
NBD_DEV=""

"$QEMU_IMG_BIN" convert -f raw -O qcow2 "$SYSTEM_RAW" "$SYSTEM_QCOW"
rm -f "$SYSTEM_RAW"
"$QEMU_IMG_BIN" create -f qcow2 "$USERDATA_QCOW" "${USERDATA_SIZE_GIB}G" >/dev/null

echo "[*] PRODUCT_OUT: $PRODUCT_OUT"
echo "[*] HOST_OUT_EXECUTABLES: $HOST_OUT_EXECUTABLES"
echo "[*] U-Boot source tree: $UBOOT_WORK_DIR"
echo "[*] U-Boot ROM: $UBOOT_ROM_OUT"
echo "[OK] System qcow2:   $SYSTEM_QCOW"
echo "[OK] Userdata qcow2: $USERDATA_QCOW"
echo "[NOTE] This branch no longer stages BOOTX64.EFI or any ESP. Use the emitted u-boot.rom as the VM bootloader/firmware artifact."
echo "[NOTE] Public Android/Cuttlefish docs build x86_64 bootloader as tools/bazel run //u-boot:qemu_x86_64_dist and consume out/u-boot/dist/u-boot.rom."
