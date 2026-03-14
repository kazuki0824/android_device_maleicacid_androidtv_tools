#!/usr/bin/env bash
#
# make_selfcontained_qcow2.v13.sh - generate a preinstalled Android-TV qcow2 from a
# system-qemu.img created by the AOSP/Lineage build system.  This script is
# intended for use with the modified build_in_docker.sh that runs
# `m superimage` and `m systemimage` on the appropriate product.  It locates
# the build output directory for the given product, copies the system-qemu
# image into a raw disk, creates a blank userdata disk, and converts both
# to qcow2 format.  The resulting qcow2 files can be used directly with
# virt-install or virt-manager: attach the system disk with serial=sd and
# the userdata disk with serial=ud.  No Recovery/Install zip is required.

set -euo pipefail

PRODUCT_RAW="${1:-}"
shift || true
if [[ -z "${PRODUCT_RAW}" ]]; then
  echo "Usage: $0 <product> [--system-size <GiB>] [--userdata-size <GiB>]" >&2
  echo "  product        : lineage_r86s_tv_virtio or lineage_qemu_tv_virtio" >&2
  echo "  --system-size  : size in GiB for the system disk (default: 16)" >&2
  echo "  --userdata-size: size in GiB for the userdata disk (default: 16)" >&2
  exit 1
fi

# Default sizes
SYSTEM_SIZE_GIB=16
USERDATA_SIZE_GIB=16

while [[ $# -gt 0 ]]; do
  case "$1" in
    --system-size)
      SYSTEM_SIZE_GIB="$2"; shift 2;;
    --userdata-size)
      USERDATA_SIZE_GIB="$2"; shift 2;;
    *)
      echo "Unknown argument: $1" >&2; exit 1;;
  esac
done

# Determine TOP by finding .repo in current working directory or parents
TOP=""
CUR="$(pwd)"
while [[ "$CUR" != "/" ]]; do
  if [[ -d "$CUR/.repo" ]]; then
    TOP="$CUR"
    break
  fi
  CUR="$(dirname "$CUR")"
done
if [[ -z "$TOP" ]]; then
  echo "[!] Could not locate Android repo root (.repo). Run this script from the build-work dir." >&2
  exit 1
fi

# Normalize product name
SHORT_PRODUCT="${PRODUCT_RAW#lineage_}"
PRODUCT="lineage_${SHORT_PRODUCT}"

# Locate PRODUCT_OUT.  In this environment the build output is typically under
#   $TOP/out-${PRODUCT}/workspace/target/product/<device>
# but we also check a few fallbacks.
PRODUCT_OUT=""
for base in "$TOP/out-${PRODUCT}" "$TOP/out-${SHORT_PRODUCT}" "$TOP/out"; do
  for sub in "workspace/target/product" "target/product"; do
    dir="$base/$sub"
    if [[ -d "$dir" ]]; then
      # find device directory inside
      for candidate in "$dir"/*; do
        if [[ -d "$candidate" && -f "$candidate/system-qemu.img" ]]; then
          PRODUCT_OUT="$candidate"
          break 3
        fi
      done
    fi
  done
done

if [[ -z "$PRODUCT_OUT" ]]; then
  echo "[!] Could not locate PRODUCT_OUT with system-qemu.img." >&2
  echo "    Looked under: $TOP/out-${PRODUCT} and $TOP/out" >&2
  echo "    Ensure you ran: m superimage && m systemimage" >&2
  echo "    Also ensure BUILD_QEMU_IMAGES := true is active for the product." >&2
  exit 1
fi

SYSTEM_QEMU_IMG="$PRODUCT_OUT/system-qemu.img"
SUPER_IMG="$PRODUCT_OUT/super.img"
BOOT_IMG="$PRODUCT_OUT/boot.img"
VENDOR_BOOT_IMG="$PRODUCT_OUT/vendor_boot.img"

if [[ ! -f "$SYSTEM_QEMU_IMG" ]]; then
  echo "[!] system-qemu.img not found at $SYSTEM_QEMU_IMG. Ensure BUILD_QEMU_IMAGES is enabled and systemimage built." >&2
  exit 1
fi

# Prepare output directory for qcow2
OUTPUT_DIR="$PRODUCT_OUT/preinstalled"
mkdir -p "$OUTPUT_DIR"

SYSTEM_QCOW="$OUTPUT_DIR/androidtv-${PRODUCT}.qcow2"
USERDATA_QCOW="$OUTPUT_DIR/androidtv-${PRODUCT}-userdata.qcow2"

echo "[*] Found PRODUCT_OUT: $PRODUCT_OUT"
echo "[*] Using system-qemu.img: $SYSTEM_QEMU_IMG"
echo "[*] Creating system qcow2: $SYSTEM_QCOW (size ${SYSTEM_SIZE_GIB}GiB)"
echo "[*] Creating userdata qcow2: $USERDATA_QCOW (size ${USERDATA_SIZE_GIB}GiB)"

# Convert system-qemu.img into qcow2 and resize
qemu-img convert -O qcow2 "$SYSTEM_QEMU_IMG" "$SYSTEM_QCOW"
qemu-img resize "$SYSTEM_QCOW" ${SYSTEM_SIZE_GIB}G

# Create blank userdata qcow2
qemu-img create -f qcow2 "$USERDATA_QCOW" ${USERDATA_SIZE_GIB}G

echo "[OK] Preinstalled system qcow2 and userdata qcow2 created."
echo "    System : $SYSTEM_QCOW"
echo "    Userdata: $USERDATA_QCOW"
echo "Note: attach system disk with serial=sd and userdata disk with serial=ud when starting the VM."
