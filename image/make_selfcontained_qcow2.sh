#!/usr/bin/env bash
set -euo pipefail

# Build a U-Boot-first preinstalled Android TV qcow2 for virtio x86_64.
#
# v16.4 changes from v16.3:
#   - Do NOT clone U-Boot ad-hoc.
#   - Use repo-managed AOSP external/u-boot and external/dtc from the Android tree.
#   - Build U-Boot with its own make/Kbuild, not Android m.
#   - Use host PATH tools (sgdisk, qemu-img, qemu-nbd, mkfs.vfat, etc.) for disk work.
#
# Run from Android build root (./.repo must exist).
#
# Requires in the repo manifest / synced tree:
#   external/u-boot
#   external/dtc
#
# Usage:
#   sudo ../android_device_maleicacid_androidtv_tools/image/make_selfcontained_qcow2.v16.3.sh lineage_qemu_tv_virtio
#
# Optional:
#   --system-size 16         # GiB, default 16
#   --userdata-size 16       # GiB, default 16
#   --esp-size-mib 128       # MiB, default 128
#   --release ap2a
#   --variant userdebug
#   --uboot-src-dir /path/to/external/u-boot
#   --dtc-src-dir /path/to/external/dtc
#   --uboot-build-dir /path/to/build
#   --uenv /path/to/uEnv.txt
#   --boot-script /path/to/boot.scr.uimg

PRODUCT="${1:-}"
shift || true
[[ -n "$PRODUCT" ]] || { echo "Usage: $0 <product> [options]" >&2; exit 1; }

RELEASE="ap2a"
VARIANT="userdebug"
SYSTEM_SIZE_GIB=16
USERDATA_SIZE_GIB=16
ESP_SIZE_MIB=128
UENV_FILE=""
BOOT_SCRIPT=""
UBOOT_SRC_DIR=""
DTC_SRC_DIR=""
UBOOT_BUILD_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --release) RELEASE="$2"; shift 2 ;;
    --variant) VARIANT="$2"; shift 2 ;;
    --system-size) SYSTEM_SIZE_GIB="$2"; shift 2 ;;
    --userdata-size) USERDATA_SIZE_GIB="$2"; shift 2 ;;
    --esp-size-mib) ESP_SIZE_MIB="$2"; shift 2 ;;
    --uenv) UENV_FILE="$2"; shift 2 ;;
    --boot-script) BOOT_SCRIPT="$2"; shift 2 ;;
    --uboot-src-dir) UBOOT_SRC_DIR="$2"; shift 2 ;;
    --dtc-src-dir) DTC_SRC_DIR="$2"; shift 2 ;;
    --uboot-build-dir) UBOOT_BUILD_DIR="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

[[ -d ./.repo ]] || { echo "[!] Run this script from the Android build root (./.repo must exist)." >&2; exit 1; }
[[ -z "$UENV_FILE" || -f "$UENV_FILE" ]] || { echo "[!] uEnv file not found: $UENV_FILE" >&2; exit 1; }
[[ -z "$BOOT_SCRIPT" || -f "$BOOT_SCRIPT" ]] || { echo "[!] boot script not found: $BOOT_SCRIPT" >&2; exit 1; }

require_host_tool() {
  local name="$1"
  local path
  path="$(command -v "$name" || true)"
  [[ -n "$path" ]] || { echo "[!] Required host tool not found in PATH: $name" >&2; exit 1; }
  printf '%s\n' "$path"
}

SGDISK_BIN="$(require_host_tool sgdisk)"
PARTPROBE_BIN="$(require_host_tool partprobe)"
MKFS_VFAT_BIN="$(require_host_tool mkfs.vfat)"
MKFS_EXT4_BIN="$(require_host_tool mkfs.ext4)"
QEMU_IMG_BIN="$(require_host_tool qemu-img)"
QEMU_NBD_BIN="$(require_host_tool qemu-nbd)"
MODPROBE_BIN="$(command -v modprobe || true)"
GIT_BIN="$(require_host_tool git)"
MAKE_BIN="$(require_host_tool make)"
GCC_BIN="$(require_host_tool gcc)"

TOP="$(pwd -P)"
SHORT_PRODUCT="$PRODUCT"
[[ "$SHORT_PRODUCT" == lineage_* ]] && SHORT_PRODUCT="${SHORT_PRODUCT#lineage_}"

# envsetup.sh is not nounset-safe.
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

if [[ -z "$UBOOT_SRC_DIR" ]]; then
  UBOOT_SRC_DIR="$TOP/external/u-boot"
fi
if [[ -z "$DTC_SRC_DIR" ]]; then
  DTC_SRC_DIR="$TOP/external/dtc"
fi
[[ -d "$UBOOT_SRC_DIR/.git" || -f "$UBOOT_SRC_DIR/Makefile" ]] || { echo "[!] external/u-boot not found at: $UBOOT_SRC_DIR" >&2; exit 1; }
[[ -d "$DTC_SRC_DIR/libfdt" ]] || { echo "[!] external/dtc/libfdt not found at: $DTC_SRC_DIR/libfdt" >&2; exit 1; }

prepare_uboot_tree() {
  # AOSP external/u-boot keeps references to in-tree libfdt locations such as
  #   include/linux/libfdt.h -> ../scripts/dtc/libfdt/libfdt.h
  # and host dtc builds also expect scripts/dtc/libfdt. Since AOSP splits dtc out
  # into external/dtc, recreate the expected paths as symlinks inside external/u-boot.
  mkdir -p "$UBOOT_SRC_DIR/scripts/dtc" "$UBOOT_SRC_DIR/include/scripts/dtc"
  ln -sfn "$DTC_SRC_DIR/libfdt" "$UBOOT_SRC_DIR/scripts/dtc/libfdt"
  ln -sfn "$DTC_SRC_DIR/libfdt" "$UBOOT_SRC_DIR/include/scripts/dtc/libfdt"
}

OUTPUT_DIR="$PRODUCT_OUT/preinstalled"
mkdir -p "$OUTPUT_DIR"

if [[ -z "$UBOOT_BUILD_DIR" ]]; then
  UBOOT_BUILD_DIR="$OUTPUT_DIR/u-boot-build-aosp-main"
fi

build_uboot_efi_app() {
  mkdir -p "$UBOOT_BUILD_DIR"
  prepare_uboot_tree
  echo "[*] Building repo-managed AOSP external/u-boot as x86_64 EFI application..."
  "$MAKE_BIN" -C "$UBOOT_SRC_DIR" O="$UBOOT_BUILD_DIR" efi-x86_app64_defconfig >/dev/null

  if [[ -x "$UBOOT_SRC_DIR/scripts/config" ]]; then
    "$UBOOT_SRC_DIR/scripts/config" --file "$UBOOT_BUILD_DIR/.config" \
      -e CMD_BOOT_ANDROID \
      -e VIRTIO \
      -e VIRTIO_BLK \
      -e CMD_VIRTIO \
      -e PARTITIONS \
      -e EFI_PARTITION \
      -e DOS_PARTITION \
      -e PARTITION_UUIDS \
      -e CMD_GPT \
      -e CMD_PART \
      -e CMD_FS_GENERIC \
      -e CMD_FAT \
      -e CMD_EXT4 \
      -e EFI_LOADER || true
    "$UBOOT_SRC_DIR/scripts/config" --file "$UBOOT_BUILD_DIR/.config" --set-val BOOTDELAY 0 || true
    "$UBOOT_SRC_DIR/scripts/config" --file "$UBOOT_BUILD_DIR/.config" \
      --set-str BOOTCOMMAND 'virtio scan; boot_android virtio 0;misc a' || true
    "$MAKE_BIN" -C "$UBOOT_SRC_DIR" O="$UBOOT_BUILD_DIR" olddefconfig >/dev/null
  fi

  local hostcflags="${HOSTCFLAGS:-} -I$DTC_SRC_DIR/libfdt"
  local hostcppflags="${HOSTCPPFLAGS:-} -I$DTC_SRC_DIR/libfdt"
  "$MAKE_BIN" -C "$UBOOT_SRC_DIR" O="$UBOOT_BUILD_DIR" \
    HOSTCFLAGS="$hostcflags" HOSTCPPFLAGS="$hostcppflags" \
    -j"$(nproc)"
}

find_uboot_efi_binary() {
  local cand
  for cand in \
    "$UBOOT_BUILD_DIR/u-boot-app.efi" \
    "$UBOOT_BUILD_DIR/u-boot.efi" \
    "$UBOOT_BUILD_DIR/u-boot-payload.efi"; do
    [[ -f "$cand" ]] && { echo "$cand"; return 0; }
  done
  return 1
}

build_uboot_efi_app
UBOOT_EFI="$(find_uboot_efi_binary)" || {
  echo "[!] Built U-Boot EFI binary not found under $UBOOT_BUILD_DIR" >&2
  exit 1
}

# Generate disabled vbmeta if missing.
if [[ ! -f "$VBMETA_IMG" ]]; then
  echo "[*] Creating disabled vbmeta.img at $VBMETA_IMG"
  "$AVBTOOL" make_vbmeta_image --flag 2 --padding_size 4096 --output "$VBMETA_IMG"
fi

TMPDIR="$(mktemp -d)"
ESP_MOUNT="$TMPDIR/esp"
mkdir -p "$ESP_MOUNT"
NBD_DEV=""
cleanup() {
  set +e
  sync
  mountpoint -q "$ESP_MOUNT" && umount "$ESP_MOUNT" >/dev/null 2>&1 || true
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

rm -f "$SYSTEM_RAW" "$SYSTEM_QCOW" "$USERDATA_QCOW"
"$QEMU_IMG_BIN" create -f raw "$SYSTEM_RAW" "${SYSTEM_SIZE_GIB}G" >/dev/null
[[ -n "$MODPROBE_BIN" ]] && "$MODPROBE_BIN" nbd max_part=32 >/dev/null 2>&1 || true
NBD_DEV=/dev/nbd0
"$QEMU_NBD_BIN" --disconnect "$NBD_DEV" >/dev/null 2>&1 || true
"$QEMU_NBD_BIN" --format=raw --connect "$NBD_DEV" "$SYSTEM_RAW"
"$PARTPROBE_BIN" "$NBD_DEV" || true
sleep 1
"$SGDISK_BIN" --clear "$NBD_DEV"
"$SGDISK_BIN" --new=1:0:+${ESP_SIZE_MIB}M    --typecode=1:ef00 --change-name=1:EFI           "$NBD_DEV"
"$SGDISK_BIN" --new=2:0:+${MISC_MIB}M        --typecode=2:8300 --change-name=2:misc          "$NBD_DEV"
"$SGDISK_BIN" --new=3:0:+${BOOT_MIB}M        --typecode=3:8300 --change-name=3:boot_a        "$NBD_DEV"
"$SGDISK_BIN" --new=4:0:+${VENDOR_BOOT_MIB}M --typecode=4:8300 --change-name=4:vendor_boot_a "$NBD_DEV"
"$SGDISK_BIN" --new=5:0:+${VBMETA_MIB}M      --typecode=5:8300 --change-name=5:vbmeta_a      "$NBD_DEV"
"$SGDISK_BIN" --new=6:0:+${SUPER_MIB}M       --typecode=6:8300 --change-name=6:super         "$NBD_DEV"
"$SGDISK_BIN" --new=7:0:+${PERSIST_MIB}M     --typecode=7:8300 --change-name=7:persist       "$NBD_DEV"
"$SGDISK_BIN" --new=8:0:+${METADATA_MIB}M    --typecode=8:8300 --change-name=8:metadata      "$NBD_DEV"
"$PARTPROBE_BIN" "$NBD_DEV" || true
sleep 1

"$MKFS_VFAT_BIN" -F 32 -n EFI "${NBD_DEV}p1" >/dev/null
mount "${NBD_DEV}p1" "$ESP_MOUNT"
mkdir -p "$ESP_MOUNT/EFI/BOOT"
cp "$UBOOT_EFI" "$ESP_MOUNT/EFI/BOOT/BOOTX64.EFI"

if [[ -n "$UENV_FILE" ]]; then
  cp "$UENV_FILE" "$ESP_MOUNT/uEnv.txt"
else
  cat > "$ESP_MOUNT/uEnv.txt" <<'ENV'
bootdelay=0
bootcmd=virtio scan; boot_android virtio 0;misc a
ENV
fi

if [[ -n "$BOOT_SCRIPT" ]]; then
  cp "$BOOT_SCRIPT" "$ESP_MOUNT/boot.scr.uimg"
fi
sync
umount "$ESP_MOUNT"

# Write Android payload partitions.
dd if=/dev/zero of="${NBD_DEV}p2" bs=1M count="$MISC_MIB" conv=fsync,notrunc status=none
if [[ -f "$PERSIST_IMG" ]]; then
  dd if="$PERSIST_IMG" of="${NBD_DEV}p7" bs=4M conv=fsync,notrunc status=progress
else
  "$MKFS_EXT4_BIN" -F -L persist "${NBD_DEV}p7" >/dev/null 2>&1 || true
fi
"$MKFS_EXT4_BIN" -F -L metadata "${NBD_DEV}p8" >/dev/null 2>&1 || true

dd if="$BOOT_IMG"        of="${NBD_DEV}p3" bs=4M conv=fsync,notrunc status=progress
dd if="$VENDOR_BOOT_IMG" of="${NBD_DEV}p4" bs=4M conv=fsync,notrunc status=progress
dd if="$VBMETA_IMG"      of="${NBD_DEV}p5" bs=4M conv=fsync,notrunc status=progress
dd if="$SUPER_RAW"       of="${NBD_DEV}p6" bs=4M conv=fsync,notrunc status=progress

sync
"$QEMU_NBD_BIN" --disconnect "$NBD_DEV"
NBD_DEV=""

"$QEMU_IMG_BIN" convert -f raw -O qcow2 "$SYSTEM_RAW" "$SYSTEM_QCOW"
rm -f "$SYSTEM_RAW"
"$QEMU_IMG_BIN" create -f qcow2 "$USERDATA_QCOW" "${USERDATA_SIZE_GIB}G" >/dev/null

echo "[*] PRODUCT_OUT: $PRODUCT_OUT"
echo "[*] HOST_OUT_EXECUTABLES: $HOST_OUT_EXECUTABLES"
echo "[*] U-Boot source: $UBOOT_SRC_DIR"
echo "[*] DTC source: $DTC_SRC_DIR"
echo "[*] Prepared libfdt links under: $UBOOT_SRC_DIR/scripts/dtc and $UBOOT_SRC_DIR/include/scripts/dtc"
echo "[*] U-Boot EFI binary: $UBOOT_EFI"
echo "[OK] System qcow2:   $SYSTEM_QCOW"
echo "[OK] Userdata qcow2: $USERDATA_QCOW"
echo "[NOTE] v16.4 assumes stock AOSP external/u-boot boot_android is reachable with: virtio scan; boot_android virtio 0;misc a"
