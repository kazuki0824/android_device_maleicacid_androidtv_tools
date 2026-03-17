#!/usr/bin/env bash
set -euo pipefail

# Build a U-Boot-first preinstalled Android TV qcow2 for virtio x86_64.
#
# v16.5.11 changes from v16.5.10:
#   - Temporarily patch boot/android_bootloader.c so its bcb_get() call matches the
#     2-argument bcb_get() prototype present in this checkout's include/bcb.h.
#
# v16.5.10 changes from v16.5.9:
#   - Recreate external/u-boot/lib/libxbc symlinks so Android boot image support can include
#     libxbc headers from bootable/libbootloader/libxbc in this repo checkout.
#
# v16.5.8 changes from v16.5.7:
#   - Replace the brittle exact grep for CONFIG_BOOTCOMMAND with a small parser that accepts the
#     one- and two-backslash serializations seen in Kconfig/.config workflows and prints the actual
#     line on mismatch.
#
# v16.5.5 changes from v16.5.4:
#   - Enable the Android boot command and required Android/AB config symbols explicitly.
#   - Stop masking scripts/config failures with `|| true` for critical U-Boot configuration.
#   - Use a bootcmd that follows U-Boot command-line grammar by escaping the semicolon in
#     the partition-name form understood by boot_android: 0\;misc.
#   - Keep the temporary top-level Makefile patch that switches EFI objcopy to --output-target.
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
#   bootable/libbootloader
#
# Usage:
#   sudo ../android_device_maleicacid_androidtv_tools/image/make_selfcontained_qcow2.v16.5.10.sh lineage_qemu_tv_virtio
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
SED_BIN="$(require_host_tool sed)"

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
if [[ -z "${LIBBOOTLOADER_XBC_DIR:-}" ]]; then
  LIBBOOTLOADER_XBC_DIR="$TOP/bootable/libbootloader/libxbc"
fi
[[ -d "$UBOOT_SRC_DIR/.git" || -f "$UBOOT_SRC_DIR/Makefile" ]] || { echo "[!] external/u-boot not found at: $UBOOT_SRC_DIR" >&2; exit 1; }
[[ -d "$DTC_SRC_DIR/libfdt" ]] || { echo "[!] external/dtc/libfdt not found at: $DTC_SRC_DIR/libfdt" >&2; exit 1; }
[[ -d "$LIBBOOTLOADER_XBC_DIR" ]] || { echo "[!] bootable/libbootloader/libxbc not found at: $LIBBOOTLOADER_XBC_DIR" >&2; exit 1; }

prepare_uboot_tree() {
  # AOSP external/u-boot keeps references to in-tree libfdt locations such as
  #   include/linux/libfdt.h -> ../scripts/dtc/libfdt/libfdt.h
  # and host dtc builds also expect scripts/dtc/libfdt. Since AOSP splits dtc out
  # into external/dtc, recreate the expected paths as symlinks inside external/u-boot.
  mkdir -p "$UBOOT_SRC_DIR/scripts/dtc" "$UBOOT_SRC_DIR/include/scripts/dtc"
  ln -sfn "$DTC_SRC_DIR/libfdt" "$UBOOT_SRC_DIR/scripts/dtc/libfdt"
  ln -sfn "$DTC_SRC_DIR/libfdt" "$UBOOT_SRC_DIR/include/scripts/dtc/libfdt"

  # Android boot image support in AOSP external/u-boot expects lib/libxbc/* to resolve into
  # bootable/libbootloader/libxbc. Recreate those symlinks explicitly so broken relative links
  # in a mixed Lineage/AOSP checkout do not break image-android.c builds.
  mkdir -p "$UBOOT_SRC_DIR/lib/libxbc"
  rm -f "$UBOOT_SRC_DIR/lib/libxbc/COPYING" \
        "$UBOOT_SRC_DIR/lib/libxbc/libxbc.c" \
        "$UBOOT_SRC_DIR/lib/libxbc/libxbc.h"
  ln -sfn "$LIBBOOTLOADER_XBC_DIR/COPYING" "$UBOOT_SRC_DIR/lib/libxbc/COPYING"
  ln -sfn "$LIBBOOTLOADER_XBC_DIR/libxbc.c" "$UBOOT_SRC_DIR/lib/libxbc/libxbc.c"
  ln -sfn "$LIBBOOTLOADER_XBC_DIR/libxbc.h" "$UBOOT_SRC_DIR/lib/libxbc/libxbc.h"
}

OUTPUT_DIR="$PRODUCT_OUT/preinstalled"
mkdir -p "$OUTPUT_DIR"

if [[ -z "$UBOOT_BUILD_DIR" ]]; then
  UBOOT_BUILD_DIR="$OUTPUT_DIR/u-boot-build-aosp-main"
fi


TMPDIR=""
ESP_MOUNT=""
NBD_DEV=""
UBOOT_PATCHED_FILE=""
UBOOT_PATCHED_FILE_BAK=""
UBOOT_ANDROID_BOOTLOADER_PATCHED_FILE=""
UBOOT_ANDROID_BOOTLOADER_PATCHED_FILE_BAK=""

restore_uboot_source_patches_if_needed() {
  if [[ -n "${UBOOT_ANDROID_BOOTLOADER_PATCHED_FILE_BAK:-}" && -f "${UBOOT_ANDROID_BOOTLOADER_PATCHED_FILE_BAK:-}" && -n "${UBOOT_ANDROID_BOOTLOADER_PATCHED_FILE:-}" ]]; then
    mv -f "$UBOOT_ANDROID_BOOTLOADER_PATCHED_FILE_BAK" "$UBOOT_ANDROID_BOOTLOADER_PATCHED_FILE"
    UBOOT_ANDROID_BOOTLOADER_PATCHED_FILE=""
    UBOOT_ANDROID_BOOTLOADER_PATCHED_FILE_BAK=""
  fi
  if [[ -n "${UBOOT_PATCHED_FILE_BAK:-}" && -f "${UBOOT_PATCHED_FILE_BAK:-}" && -n "${UBOOT_PATCHED_FILE:-}" ]]; then
    mv -f "$UBOOT_PATCHED_FILE_BAK" "$UBOOT_PATCHED_FILE"
    UBOOT_PATCHED_FILE=""
    UBOOT_PATCHED_FILE_BAK=""
  fi
}

patch_uboot_source_for_efi_objcopy() {
  local makefile="$UBOOT_SRC_DIR/Makefile"
  local needle='OBJCOPYFLAGS_u-boot-payload.efi := $(OBJCOPYFLAGS_EFI)'
  local replacement='OBJCOPYFLAGS_u-boot-payload.efi := $(patsubst --target=%,--output-target=%,$(OBJCOPYFLAGS_EFI))'

  [[ -f "$makefile" ]] || {
    echo "[!] Missing expected U-Boot Makefile: $makefile" >&2
    exit 1
  }

  if grep -Fq -- "$replacement" "$makefile"; then
    echo "[*] $makefile already patches u-boot-payload.efi to use --output-target."
    return 0
  fi

  grep -Fq -- "$needle" "$makefile" || {
    echo "[!] Could not find OBJCOPYFLAGS_u-boot-payload.efi pattern in $makefile" >&2
    exit 1
  }

  UBOOT_PATCHED_FILE="$makefile"
  UBOOT_PATCHED_FILE_BAK="$(mktemp "${TMPDIR:-/tmp}/u-boot-Makefile.XXXXXX")"
  cp -a "$makefile" "$UBOOT_PATCHED_FILE_BAK"
  python3 - "$makefile" <<'PYCODE'
from pathlib import Path
import sys
path = Path(sys.argv[1])
old = 'OBJCOPYFLAGS_u-boot-payload.efi := $(OBJCOPYFLAGS_EFI)'
new = 'OBJCOPYFLAGS_u-boot-payload.efi := $(patsubst --target=%,--output-target=%,$(OBJCOPYFLAGS_EFI))'
text = path.read_text()
if old not in text:
    raise SystemExit(f"[!] Could not find patch needle in {path}")
path.write_text(text.replace(old, new, 1))
PYCODE
}

patch_uboot_android_bootloader_bcb_call_if_needed() {
  local srcfile="$UBOOT_SRC_DIR/boot/android_bootloader.c"
  local needle='bcb_get(BCB_FIELD_COMMAND, bcb_command, sizeof(bcb_command))'
  local replacement='bcb_get(BCB_FIELD_COMMAND, bcb_command)'

  [[ -f "$srcfile" ]] || {
    echo "[!] Missing expected U-Boot source file: $srcfile" >&2
    exit 1
  }

  if grep -Fq -- "$replacement" "$srcfile"; then
    echo "[*] $srcfile already uses 2-argument bcb_get()."
    return 0
  fi

  grep -Fq -- "$needle" "$srcfile" || {
    echo "[!] Could not find android_bootloader.c bcb_get() call pattern in $srcfile" >&2
    exit 1
  }

  UBOOT_ANDROID_BOOTLOADER_PATCHED_FILE="$srcfile"
  UBOOT_ANDROID_BOOTLOADER_PATCHED_FILE_BAK="$(mktemp "${TMPDIR:-/tmp}/u-boot-android_bootloader.c.XXXXXX")"
  cp -a "$srcfile" "$UBOOT_ANDROID_BOOTLOADER_PATCHED_FILE_BAK"
  python3 - "$srcfile" <<'PYCODE'
from pathlib import Path
import sys
path = Path(sys.argv[1])
old = 'bcb_get(BCB_FIELD_COMMAND, bcb_command, sizeof(bcb_command))'
new = 'bcb_get(BCB_FIELD_COMMAND, bcb_command)'
text = path.read_text()
if old not in text:
    raise SystemExit(f"[!] Could not find patch needle in {path}")
path.write_text(text.replace(old, new, 1))
PYCODE
}

cleanup() {
  set +e
  sync
  if [[ -n "$ESP_MOUNT" ]]; then
    mountpoint -q "$ESP_MOUNT" && umount "$ESP_MOUNT" >/dev/null 2>&1 || true
  fi
  [[ -n "$NBD_DEV" ]] && "$QEMU_NBD_BIN" --disconnect "$NBD_DEV" >/dev/null 2>&1 || true
  restore_uboot_source_patches_if_needed
  [[ -n "$TMPDIR" ]] && rm -rf "$TMPDIR"
}
trap cleanup EXIT

build_uboot_efi_payload() {
  mkdir -p "$UBOOT_BUILD_DIR"
  prepare_uboot_tree
  patch_uboot_source_for_efi_objcopy
  patch_uboot_android_bootloader_bcb_call_if_needed
  echo "[*] Building repo-managed AOSP external/u-boot as x86_64 EFI payload..."
  "$MAKE_BIN" -C "$UBOOT_SRC_DIR" O="$UBOOT_BUILD_DIR" efi-x86_payload64_defconfig >/dev/null

  if [[ -x "$UBOOT_SRC_DIR/scripts/config" ]]; then
    "$UBOOT_SRC_DIR/scripts/config" --file "$UBOOT_BUILD_DIR/.config" \
      -e ANDROID_BOOT_IMAGE \
      -e ANDROID_BOOTLOADER \
      -e ANDROID_AB \
      -e CMD_AB_SELECT \
      -e CMD_BOOT_ANDROID \
      -e LIBAVB \
      -e AVB_VERIFY \
      -e CMD_AVB \
      -e XBC \
      -e VIRTIO \
      -e VIRTIO_BLK \
      -e PARTITIONS \
      -e EFI_PARTITION \
      -e DOS_PARTITION \
      -e PARTITION_UUIDS \
      -e CMD_GPT \
      -e CMD_PART \
      -e CMD_FS_GENERIC \
      -e CMD_FAT \
      -e CMD_EXT4
    "$UBOOT_SRC_DIR/scripts/config" --file "$UBOOT_BUILD_DIR/.config" --set-val BOOTDELAY 0
    "$UBOOT_SRC_DIR/scripts/config" --file "$UBOOT_BUILD_DIR/.config" \
      --set-str BOOTCOMMAND 'boot_android virtio 0:2 a'
    "$MAKE_BIN" -C "$UBOOT_SRC_DIR" O="$UBOOT_BUILD_DIR" olddefconfig >/dev/null

    grep -Eq '^CONFIG_ANDROID_BOOT_IMAGE=y$' "$UBOOT_BUILD_DIR/.config"
    grep -Eq '^CONFIG_ANDROID_BOOTLOADER=y$' "$UBOOT_BUILD_DIR/.config"
    grep -Eq '^CONFIG_ANDROID_AB=y$' "$UBOOT_BUILD_DIR/.config"
    grep -Eq '^CONFIG_CMD_AB_SELECT=y$' "$UBOOT_BUILD_DIR/.config"
    grep -Eq '^CONFIG_CMD_BOOT_ANDROID=y$' "$UBOOT_BUILD_DIR/.config"
    grep -Eq '^CONFIG_LIBAVB=y$' "$UBOOT_BUILD_DIR/.config"
    grep -Eq '^CONFIG_AVB_VERIFY=y$' "$UBOOT_BUILD_DIR/.config"
    grep -Eq '^CONFIG_CMD_AVB=y$' "$UBOOT_BUILD_DIR/.config"
    grep -Eq '^CONFIG_XBC=y$' "$UBOOT_BUILD_DIR/.config"
    grep -Eq '^CONFIG_BOOTDELAY=0$' "$UBOOT_BUILD_DIR/.config"
    python3 - "$UBOOT_BUILD_DIR/.config" <<'PY'
from pathlib import Path
import sys

cfg = Path(sys.argv[1])
line = None
for raw in cfg.read_text().splitlines():
    if raw.startswith("CONFIG_BOOTCOMMAND="):
        line = raw
        break

allowed = {
    r'CONFIG_BOOTCOMMAND="boot_android virtio 0:2 a"',
}

if line not in allowed:
    print("[!] Unexpected CONFIG_BOOTCOMMAND in .config:", file=sys.stderr)
    print(f"    {line!r}", file=sys.stderr)
    raise SystemExit(1)
PY
  fi

  local hostcflags="${HOSTCFLAGS:-} -I$DTC_SRC_DIR/libfdt"
  local hostcppflags="${HOSTCPPFLAGS:-} -I$DTC_SRC_DIR/libfdt"
  local objcopy_bin="${OBJCOPY_BIN:-$(command -v x86_64-linux-gnu-objcopy || command -v objcopy)}"
  "$MAKE_BIN" -C "$UBOOT_SRC_DIR" O="$UBOOT_BUILD_DIR"     HOSTCFLAGS="$hostcflags" HOSTCPPFLAGS="$hostcppflags"     OBJCOPY="$objcopy_bin"     u-boot-payload.efi -j"$(nproc)"
}

find_uboot_efi_binary() {
  local cand
  for cand in \
    "$UBOOT_BUILD_DIR/u-boot-payload.efi" \
    "$UBOOT_BUILD_DIR/u-boot.efi" \
    "$UBOOT_BUILD_DIR/u-boot-app.efi"; do
    [[ -f "$cand" ]] && { echo "$cand"; return 0; }
  done
  return 1
}

build_uboot_efi_payload
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
bootcmd=boot_android virtio 0:2 a
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
echo "[*] libxbc source: $LIBBOOTLOADER_XBC_DIR"
echo "[*] Prepared libfdt links under: $UBOOT_SRC_DIR/scripts/dtc and $UBOOT_SRC_DIR/include/scripts/dtc"
echo "[*] Prepared libxbc links under: $UBOOT_SRC_DIR/lib/libxbc"
echo "[*] U-Boot EFI binary: $UBOOT_EFI"
echo "[OK] System qcow2:   $SYSTEM_QCOW"
echo "[OK] Userdata qcow2: $USERDATA_QCOW"
echo "[NOTE] v16.5.13 temporarily patches external/u-boot/Makefile so u-boot-payload.efi uses --output-target for EFI objcopy, then restores it on exit. It also prepares libxbc symlinks, enables Android boot/AB config symbols explicitly, applies the android_bootloader.c bcb_get() compatibility patch, and sets bootcmd to boot_android virtio 0:2 a."
