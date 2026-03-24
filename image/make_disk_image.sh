#!/usr/bin/env bash
set -euo pipefail

# This script must be run from the repository root directory that contains .repo.
# It does not call repo or m. It expects that the Android build has already completed.
#
# Purpose:
#   1. Verify that the stock Lineage virt/grub artifacts already exist.
#   2. Convert PRODUCT_OUT/disk-vda.img (raw) into a boot qcow2 image.
#   3. Create an empty sparse qcow2 for userdata.
#
# Default assumptions:
#   - custom product: lineage_virtio_x86_64_tv_grub
#   - PRODUCT_DEVICE: virtio_x86_64_tv_grub
#   - PRODUCT_OUT: out/target/product/virtio_x86_64_tv_grub
#
# Example:
#   ./scripts/make_disk_image.sh
#   ./scripts/make_disk_image.sh --product-out out/target/product/virtio_x86_64_tv_grub \
#       --boot-qcow2 dist/lineage21-tv-grub-boot.qcow2 \
#       --userdata-qcow2 dist/lineage21-tv-grub-userdata.qcow2 \
#       --userdata-size 32G

usage() {
    cat <<'USAGE'
Usage: ./scripts/make_disk_image.sh [options]

Options:
  --product-out PATH      PRODUCT_OUT directory.
                          Default: out/target/product/virtio_x86_64_tv_grub
  --boot-raw PATH         Prebuilt raw boot disk image.
                          Default: <product-out>/disk-vda.img
  --boot-qcow2 PATH       Output qcow2 boot disk image.
                          Default: <product-out>/disk-vda.qcow2
  --userdata-qcow2 PATH   Output empty userdata qcow2 image.
                          Default: <product-out>/userdata-empty.qcow2
  --userdata-size SIZE    Virtual size for userdata qcow2.
                          Default: 16G
  --force                 Overwrite output files if they already exist.
  -h, --help              Show this help.
USAGE
}

require_repo_root() {
    if [[ ! -d .repo ]]; then
        echo "ERROR: current directory must be the repository root containing .repo" >&2
        exit 1
    fi
}

require_tool() {
    local tool="$1"
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "ERROR: required tool not found in PATH: $tool" >&2
        exit 1
    fi
}

assert_file() {
    local path="$1"
    if [[ ! -f "$path" ]]; then
        echo "ERROR: required file not found: $path" >&2
        exit 1
    fi
}

assert_not_exists_unless_force() {
    local path="$1"
    if [[ -e "$path" && "$FORCE" != true ]]; then
        echo "ERROR: output already exists: $path" >&2
        echo "       rerun with --force to overwrite" >&2
        exit 1
    fi
}

print_summary() {
    cat <<SUMMARY
Input PRODUCT_OUT   : $PRODUCT_OUT
Input raw boot disk : $BOOT_RAW
Output boot qcow2   : $BOOT_QCOW2
Output userdata qcow2: $USERDATA_QCOW2
Userdata virtual size: $USERDATA_SIZE
SUMMARY
}

PRODUCT_OUT="out/target/product/virtio_x86_64_tv_grub"
BOOT_RAW=""
BOOT_QCOW2=""
USERDATA_QCOW2=""
USERDATA_SIZE="16G"
FORCE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --product-out)
            PRODUCT_OUT="$2"
            shift 2
            ;;
        --boot-raw)
            BOOT_RAW="$2"
            shift 2
            ;;
        --boot-qcow2)
            BOOT_QCOW2="$2"
            shift 2
            ;;
        --userdata-qcow2)
            USERDATA_QCOW2="$2"
            shift 2
            ;;
        --userdata-size)
            USERDATA_SIZE="$2"
            shift 2
            ;;
        --force)
            FORCE=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: unknown argument: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

require_repo_root
require_tool qemu-img

if [[ -z "$BOOT_RAW" ]]; then
    BOOT_RAW="$PRODUCT_OUT/disk-vda.img"
fi
if [[ -z "$BOOT_QCOW2" ]]; then
    BOOT_QCOW2="$PRODUCT_OUT/disk-vda.qcow2"
fi
if [[ -z "$USERDATA_QCOW2" ]]; then
    USERDATA_QCOW2="$PRODUCT_OUT/userdata-empty.qcow2"
fi

# Verify that the build already produced the artifacts required by the stock
# Lineage virt/grub pipeline.
assert_file "$PRODUCT_OUT/EFI.img"
assert_file "$PRODUCT_OUT/persist.img"
assert_file "$PRODUCT_OUT/boot.img"
assert_file "$PRODUCT_OUT/vendor_boot.img"
assert_file "$PRODUCT_OUT/super.img"
assert_file "$BOOT_RAW"

# BIOS/MBR are expected because the pinned BoardConfig uses i386-pc as 2nd arch.
assert_file "$PRODUCT_OUT/BIOS.img"
assert_file "$PRODUCT_OUT/MBR.img"

mkdir -p "$(dirname "$BOOT_QCOW2")"
mkdir -p "$(dirname "$USERDATA_QCOW2")"

assert_not_exists_unless_force "$BOOT_QCOW2"
assert_not_exists_unless_force "$USERDATA_QCOW2"

print_summary

echo "[1/2] Converting raw boot disk to qcow2..."
qemu-img convert -f raw -O qcow2 "$BOOT_RAW" "$BOOT_QCOW2"

echo "[2/2] Creating sparse empty userdata qcow2..."
rm -f "$USERDATA_QCOW2"
qemu-img create -f qcow2 "$USERDATA_QCOW2" "$USERDATA_SIZE" >/dev/null

echo
echo "Done."
echo "Boot qcow2    : $BOOT_QCOW2"
echo "Userdata qcow2: $USERDATA_QCOW2"
echo
echo "Suggested VM attachment order:"
echo "  - boot disk     : $BOOT_QCOW2"
echo "  - userdata disk : $USERDATA_QCOW2"
