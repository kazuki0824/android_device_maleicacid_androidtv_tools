#!/usr/bin/env bash
set -euo pipefail

# Build a preinstalled Android TV qcow2 for virtio x86_64 by generating a normal-boot
# EFI System Partition from source ingredients (kernel, ramdisk, GRUB prebuilts) and
# combining it with super/vbmeta/persist/misc/metadata partitions.
#
# Run from the Android repo root (directory containing .repo/), e.g. build-work.
#
# Usage:
#   sudo ../android_device_maleicacid_androidtv_tools/image/make_selfcontained_qcow2.v14.sh lineage_qemu_tv_virtio
#
# Optional flags:
#   --release ap2a
#   --variant userdebug
#   --system-size 16         # GiB, default 16
#   --userdata-size 16       # GiB, default 16
#   --esp-size-mib 512       # MiB, default 512
#   --with-bios              # also install BIOS GRUB bootstrap (optional)
#   --sysdev vda             # disk name used inside GRUB partition_map, default vda

PRODUCT="${1:-}"
shift || true
[[ -n "$PRODUCT" ]] || { echo "Usage: $0 <product> [options]" >&2; exit 1; }

RELEASE="ap2a"
VARIANT="userdebug"
SYSTEM_SIZE_GIB=16
USERDATA_SIZE_GIB=16
ESP_SIZE_MIB=512
WITH_BIOS=0
SYSDEV="vda"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --release) RELEASE="$2"; shift 2;;
    --variant) VARIANT="$2"; shift 2;;
    --system-size) SYSTEM_SIZE_GIB="$2"; shift 2;;
    --userdata-size) USERDATA_SIZE_GIB="$2"; shift 2;;
    --esp-size-mib) ESP_SIZE_MIB="$2"; shift 2;;
    --with-bios) WITH_BIOS=1; shift 1;;
    --sysdev) SYSDEV="$2"; shift 2;;
    *) echo "Unknown argument: $1" >&2; exit 1;;
  esac
done

find_top() {
  local d="$(pwd -P)"
  while [[ "$d" != "/" ]]; do
    [[ -d "$d/.repo" ]] && { echo "$d"; return 0; }
    d="$(dirname "$d")"
  done
  return 1
}

TOP="$(find_top)" || { echo "[!] Could not locate Android repo root (.repo)." >&2; exit 1; }

# Discover PRODUCT_OUT from actual build artifacts rather than get_build_var PRODUCT_OUT,
# because the build was done inside Docker with OUT_DIR_COMMON_BASE=/workspace/out-<product>,
# which does not map 1:1 to the host path used here.
discover_product_out() {
  local base
  for base in     "$TOP/out-${PRODUCT}/workspace/target/product"     "$TOP/out-${PRODUCT}/target/product"     "$TOP/out-${PRODUCT#lineage_}/workspace/target/product"     "$TOP/out-${PRODUCT#lineage_}/target/product"     "$TOP/out/target/product"
  do
    [[ -d "$base" ]] || continue
    local cand
    for cand in "$base"/*; do
      [[ -d "$cand" ]] || continue
      if [[ -f "$cand/kernel" && -f "$cand/ramdisk.img" && -f "$cand/super.img" ]]; then
        echo "$cand"
        return 0
      fi
    done
  done
  return 1
}

PRODUCT_OUT="$(discover_product_out)" || {
  echo "[!] Could not locate PRODUCT_OUT from built artifacts." >&2
  echo "    Expected a directory containing kernel, ramdisk.img, and super.img under:" >&2
  echo "      $TOP/out-${PRODUCT}/workspace/target/product/*" >&2
  echo "      $TOP/out-${PRODUCT}/target/product/*" >&2
  echo "      $TOP/out-${PRODUCT#lineage_}/workspace/target/product/*" >&2
  echo "      $TOP/out-${PRODUCT#lineage_}/target/product/*" >&2
  echo "      $TOP/out/target/product/*" >&2
  exit 1
}

# build/envsetup.sh is not nounset-safe. Use it only for config variables, not PRODUCT_OUT.
set +u
source "$TOP/build/envsetup.sh" >/dev/null
lunch "${PRODUCT}-${RELEASE}-${VARIANT}" >/dev/null
BOARD_KERNEL_CMDLINE="$(get_build_var BOARD_KERNEL_CMDLINE)"
set -u

HOST_OUT_EXECUTABLES="${PRODUCT_OUT%/target/product/*}/host/linux-x86/bin"
if [[ ! -d "$HOST_OUT_EXECUTABLES" ]]; then
  echo "[!] host tools dir not found: $HOST_OUT_EXECUTABLES" >&2
  exit 1
fi

KERNEL="$PRODUCT_OUT/kernel"
RAMDISK="$PRODUCT_OUT/ramdisk.img"
SUPER_IMG="$PRODUCT_OUT/super.img"
PERSIST_IMG="$PRODUCT_OUT/persist.img"
VBMETA_IMG="$PRODUCT_OUT/vbmeta.img"
AVBTOOL="$HOST_OUT_EXECUTABLES/avbtool"
SIMG2IMG="$HOST_OUT_EXECUTABLES/simg2img"
GRUB_PATCH_BIN="$HOST_OUT_EXECUTABLES/grub_i386-pc_img_patch"
GRUB_PATCH_SRC="$TOP/device/virt/virt-common/utilities/grub_i386-pc_img_patch/grub_i386-pc_img_patch.c"
PREBUILT_GRUB_TOOLS="$TOP/prebuilts/bootmgr/tools/linux-x86/bin"
GRUB_MKSTANDALONE="$TOP/prebuilts/bootmgr/grub/linux-x86/x86_64-efi/bin/grub-mkstandalone"
GRUB_EFI_LIB="$TOP/prebuilts/bootmgr/grub/linux-x86/x86_64-efi/lib/grub/x86_64-efi"
GRUB_MKIMAGE="$TOP/prebuilts/bootmgr/grub/linux-x86/i386-pc/bin/grub-mkimage"
GRUB_BIOS_LIB="$TOP/prebuilts/bootmgr/grub/linux-x86/i386-pc/lib/grub/i386-pc"

echo "[*] PRODUCT_OUT: $PRODUCT_OUT"
echo "[*] HOST_OUT_EXECUTABLES: $HOST_OUT_EXECUTABLES"

for f in "$KERNEL" "$RAMDISK" "$SUPER_IMG" "$AVBTOOL" "$GRUB_MKSTANDALONE" "$GRUB_EFI_LIB"; do
  [[ -e "$f" ]] || { echo "[!] Required input not found: $f" >&2; exit 1; }
done

TMPDIR="$(mktemp -d)"
ESP_MOUNT="$TMPDIR/esp"
mkdir -p "$ESP_MOUNT"
trap 'set +e; umount "$ESP_MOUNT" >/dev/null 2>&1 || true; [[ -n "${NBD_DEV:-}" ]] && qemu-nbd --disconnect "$NBD_DEV" >/dev/null 2>&1 || true; rm -rf "$TMPDIR"' EXIT

# If vbmeta.img does not exist, make a disabled one.
if [[ ! -f "$VBMETA_IMG" ]]; then
  echo "[*] Creating disabled vbmeta.img at $VBMETA_IMG"
  "$AVBTOOL" make_vbmeta_image --flag 2 --padding_size 4096 --output "$VBMETA_IMG"
fi

# Convert sparse super image to raw if needed.
SUPER_RAW="$TMPDIR/super.raw"
python3 - "$SUPER_IMG" "$SUPER_RAW" "$SIMG2IMG" <<'PY'
import struct, sys, shutil, subprocess, os
src, dst, simg2img = sys.argv[1:4]
with open(src, 'rb') as f:
    magic = struct.unpack('<I', f.read(4))[0]
# Android sparse magic
if magic == 0xed26ff3a:
    subprocess.check_call([simg2img, src, dst])
else:
    shutil.copyfile(src, dst)
PY

ceil_mib() {
  local bytes="$1"
  echo $(( (bytes + 1024*1024 - 1) / (1024*1024) ))
}

SUPER_MIB="$(ceil_mib "$(stat -c '%s' "$SUPER_RAW")")"
VBMETA_MIB="$(ceil_mib "$(stat -c '%s' "$VBMETA_IMG")")"
PERSIST_MIB=32
if [[ -f "$PERSIST_IMG" ]]; then
  PERSIST_MIB="$(ceil_mib "$(stat -c '%s' "$PERSIST_IMG")")"
fi
MISC_MIB=16
METADATA_MIB=64
BIOS_MIB=1

OUTPUT_DIR="$PRODUCT_OUT/preinstalled"
mkdir -p "$OUTPUT_DIR"
SYSTEM_RAW="$OUTPUT_DIR/androidtv-${PRODUCT}.raw"
SYSTEM_QCOW="$OUTPUT_DIR/androidtv-${PRODUCT}.qcow2"
USERDATA_QCOW="$OUTPUT_DIR/androidtv-${PRODUCT}-userdata.qcow2"

# Prepare raw disk and partition it.
rm -f "$SYSTEM_RAW" "$SYSTEM_QCOW" "$USERDATA_QCOW"
qemu-img create -f raw "$SYSTEM_RAW" "${SYSTEM_SIZE_GIB}G" >/dev/null
modprobe nbd max_part=32 >/dev/null 2>&1 || true
NBD_DEV=/dev/nbd0
qemu-nbd --disconnect "$NBD_DEV" >/dev/null 2>&1 || true
qemu-nbd --connect "$NBD_DEV" "$SYSTEM_RAW"
partprobe "$NBD_DEV" || true
sleep 1
sgdisk -og "$NBD_DEV"

if [[ "$WITH_BIOS" -eq 1 ]]; then
  sgdisk -n "1:0:+${ESP_SIZE_MIB}M" -t "1:ef00" -c "1:EFI" "$NBD_DEV"
  sgdisk -n "2:0:+${BIOS_MIB}M"     -t "2:ef02" -c "2:BIOS" "$NBD_DEV"
  sgdisk -n "3:0:+${SUPER_MIB}M"    -t "3:8300" -c "3:super" "$NBD_DEV"
  sgdisk -n "4:0:+${VBMETA_MIB}M"   -t "4:8300" -c "4:vbmeta" "$NBD_DEV"
  sgdisk -n "5:0:+${PERSIST_MIB}M"  -t "5:8300" -c "5:persist" "$NBD_DEV"
  sgdisk -n "6:0:+${MISC_MIB}M"     -t "6:8300" -c "6:misc" "$NBD_DEV"
  sgdisk -n "7:0:+${METADATA_MIB}M" -t "7:8300" -c "7:metadata" "$NBD_DEV"
  EFI_PART=1; BIOS_PART=2; SUPER_PART=3; VBMETA_PART=4; PERSIST_PART=5; MISC_PART=6; METADATA_PART=7
else
  sgdisk -n "1:0:+${ESP_SIZE_MIB}M" -t "1:ef00" -c "1:EFI" "$NBD_DEV"
  sgdisk -n "2:0:+${SUPER_MIB}M"    -t "2:8300" -c "2:super" "$NBD_DEV"
  sgdisk -n "3:0:+${VBMETA_MIB}M"   -t "3:8300" -c "3:vbmeta" "$NBD_DEV"
  sgdisk -n "4:0:+${PERSIST_MIB}M"  -t "4:8300" -c "4:persist" "$NBD_DEV"
  sgdisk -n "5:0:+${MISC_MIB}M"     -t "5:8300" -c "5:misc" "$NBD_DEV"
  sgdisk -n "6:0:+${METADATA_MIB}M" -t "6:8300" -c "6:metadata" "$NBD_DEV"
  EFI_PART=1; BIOS_PART=0; SUPER_PART=2; VBMETA_PART=3; PERSIST_PART=4; MISC_PART=5; METADATA_PART=6
fi
partprobe "$NBD_DEV" || true
sleep 1

# Build normal-boot GRUB config.
PMAP="${SYSDEV}${SUPER_PART},super;${SYSDEV}${VBMETA_PART},vbmeta;${SYSDEV}${PERSIST_PART},persist;${SYSDEV}${MISC_PART},misc;${SYSDEV}${METADATA_PART},metadata"
PMAP_ESCAPED="${PMAP//;/\\;}"
CMDLINE="$BOARD_KERNEL_CMDLINE"
CMDLINE="$(echo "$CMDLINE" | sed -E 's#(^| )androidboot\.partition_map=[^ ]*##g' | xargs)"
CMDLINE="$CMDLINE androidboot.partition_map=${PMAP_ESCAPED}"

cat > "$TMPDIR/grub.cfg" <<EOF2
insmod normal
insmod linux
insmod test

if [ "\$grub_platform" = "efi" ]; then
    insmod efi_gop
elif [ "\$grub_platform" = "pc" ]; then
    insmod vbe
fi

menuentry "Android" {
    set gfxpayload=keep
    linux /android/kernel $CMDLINE
    initrd /android/ramdisk.img
}
EOF2

cat > "$TMPDIR/grub-standalone.cfg" <<'EOF2'
search --file --no-floppy --set=root /android/kernel
set prefix=($root)'/boot/grub'
configfile $prefix/grub.cfg
EOF2

# Prepare EFI partition filesystem.
mkfs.vfat -F 32 -n EFI "${NBD_DEV}p${EFI_PART}" >/dev/null
mount "${NBD_DEV}p${EFI_PART}" "$ESP_MOUNT"
mkdir -p "$ESP_MOUNT/android" "$ESP_MOUNT/boot/grub" "$ESP_MOUNT/EFI/BOOT"
cp "$KERNEL" "$ESP_MOUNT/android/kernel"
cp "$RAMDISK" "$ESP_MOUNT/android/ramdisk.img"
cp "$TMPDIR/grub.cfg" "$ESP_MOUNT/boot/grub/grub.cfg"
cp -a "$GRUB_BIOS_LIB" "$ESP_MOUNT/boot/grub/i386-pc"
cp -a "$GRUB_EFI_LIB" "$ESP_MOUNT/boot/grub/x86_64-efi"
PATH="$PREBUILT_GRUB_TOOLS:$PATH" \
  "$GRUB_MKSTANDALONE" \
    -d "$GRUB_EFI_LIB" \
    --fonts="" \
    --format=x86_64-efi \
    --locales="" \
    --modules="configfile disk fat part_gpt search" \
    --output="$TMPDIR/BOOTX64.EFI" \
    "boot/grub/grub.cfg=$TMPDIR/grub-standalone.cfg"
cp "$TMPDIR/BOOTX64.EFI" "$ESP_MOUNT/EFI/BOOT/BOOTX64.EFI"
sync
umount "$ESP_MOUNT"

# Install payload partitions.
dd if="$SUPER_RAW" of="${NBD_DEV}p${SUPER_PART}" bs=4M conv=fsync,notrunc status=none
# vbmeta.img is tiny; write directly.
dd if="$VBMETA_IMG" of="${NBD_DEV}p${VBMETA_PART}" bs=1M conv=fsync,notrunc status=none
if [[ -f "$PERSIST_IMG" ]]; then
  dd if="$PERSIST_IMG" of="${NBD_DEV}p${PERSIST_PART}" bs=1M conv=fsync,notrunc status=none
else
  mkfs.ext4 -F -L persist "${NBD_DEV}p${PERSIST_PART}" >/dev/null 2>&1 || true
fi
mkfs.ext4 -F -L metadata "${NBD_DEV}p${METADATA_PART}" >/dev/null 2>&1 || true

# Optional BIOS support.
if [[ "$WITH_BIOS" -eq 1 ]]; then
  if [[ ! -x "$GRUB_PATCH_BIN" ]]; then
    if [[ -f "$GRUB_PATCH_SRC" ]]; then
      gcc "$GRUB_PATCH_SRC" -o "$GRUB_PATCH_BIN"
    else
      echo "[!] BIOS support requested but grub_i386-pc_img_patch not available." >&2
      exit 1
    fi
  fi
  cp "$GRUB_BIOS_LIB/boot.img" "$TMPDIR/boot.img.full"
  # Only MBR boot code (446 bytes) is written to the disk later.
  PATH="$PREBUILT_GRUB_TOOLS:$PATH" \
    "$GRUB_MKIMAGE" \
      --compression=auto \
      --config="$TMPDIR/grub-standalone.cfg" \
      --directory="$GRUB_BIOS_LIB" \
      --format=i386-pc \
      --output="$TMPDIR/core.img" \
      --prefix=/boot/grub \
      fat part_gpt biosdisk search configfile
  START_SECTOR="$(sgdisk -i "$BIOS_PART" "$NBD_DEV" | awk -F': ' '/First sector/ {print $2}')"
  "$GRUB_PATCH_BIN" "$START_SECTOR" "$TMPDIR/boot.img.full" "$TMPDIR/core.img"
  dd if="$TMPDIR/boot.img.full" of="$NBD_DEV" bs=446 count=1 conv=fsync,notrunc status=none
  dd if="$TMPDIR/core.img" of="$NBD_DEV" bs=512 seek="$START_SECTOR" conv=fsync,notrunc status=none
fi

qemu-nbd --disconnect "$NBD_DEV"
NBD_DEV=""

qemu-img convert -f raw -O qcow2 "$SYSTEM_RAW" "$SYSTEM_QCOW"
qemu-img create -f qcow2 "$USERDATA_QCOW" "${USERDATA_SIZE_GIB}G" >/dev/null

cat <<EOF2
[OK] Created preinstalled system disk and blank userdata disk:
  System  : $SYSTEM_QCOW
  Userdata: $USERDATA_QCOW

Use with virt-install / libvirt:
  --disk path=$SYSTEM_QCOW,format=qcow2,bus=virtio,serial=sd
  --disk path=$USERDATA_QCOW,format=qcow2,bus=virtio,serial=ud
EOF2
