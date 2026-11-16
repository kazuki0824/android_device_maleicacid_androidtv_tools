#!/usr/bin/env bash
set -euo pipefail

# This script must be run from the repository root directory that contains .repo.
# It does not call repo or m. It expects that the Android build has already completed.
#
# Purpose:
#   1. Verify that the stock Lineage virt/grub artifacts already exist.
#   2. Convert PRODUCT_OUT/disk-vda.img (raw) into a boot qcow2 image.
#   3. Create an empty sparse qcow2 for userdata.
#   4. Create a GPT metadata disk, retained together with userdata.
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
  --metadata-qcow2 PATH   Output empty GPT metadata disk (34 MiB).
                          Default: <product-out>/metadata-empty.qcow2
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
Output metadata qcow2: $METADATA_QCOW2
Userdata virtual size: $USERDATA_SIZE
SUMMARY
}

PRODUCT_OUT="out/target/product/virtio_x86_64_tv_grub"
BOOT_RAW=""
BOOT_QCOW2=""
USERDATA_QCOW2=""
METADATA_QCOW2=""
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
        --metadata-qcow2)
            METADATA_QCOW2="$2"
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
require_tool sgdisk

if [[ -z "$BOOT_RAW" ]]; then
    BOOT_RAW="$PRODUCT_OUT/disk-vda.img"
fi
if [[ -z "$BOOT_QCOW2" ]]; then
    BOOT_QCOW2="$PRODUCT_OUT/disk-vda.qcow2"
fi
if [[ -z "$USERDATA_QCOW2" ]]; then
    USERDATA_QCOW2="$PRODUCT_OUT/userdata-empty.qcow2"
fi
if [[ -z "$METADATA_QCOW2" ]]; then
    METADATA_QCOW2="$PRODUCT_OUT/metadata-empty.qcow2"
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
mkdir -p "$(dirname "$METADATA_QCOW2")"

assert_not_exists_unless_force "$BOOT_QCOW2"
assert_not_exists_unless_force "$USERDATA_QCOW2"
assert_not_exists_unless_force "$METADATA_QCOW2"

# Reject aliases before --force can replace either an input or another output.
paths=("$BOOT_RAW" "$BOOT_QCOW2" "$USERDATA_QCOW2" "$METADATA_QCOW2")
declare -A seen_paths=()
for path in "${paths[@]}"; do
    canonical_path=$(realpath -m "$path")
    if [[ -n "${seen_paths[$canonical_path]+present}" ]]; then
        echo "ERROR: input and output paths must be distinct: $path" >&2
        exit 1
    fi
    seen_paths[$canonical_path]=1
done

# Select by GPT name, supporting both the A/B and non-A/B upstream layouts.
partition_table=$(sgdisk --print "$BOOT_RAW")
mapfile -t metadata_partitions < <(
    awk '$1 ~ /^[0-9]+$/ && $NF == "metadata" {print $1}' <<< "$partition_table"
)
if [[ ${#metadata_partitions[@]} -ne 1 ]]; then
    echo "ERROR: boot disk must contain exactly one GPT partition named metadata" >&2
    exit 1
fi

work_dir=$(mktemp -d "${BOOT_QCOW2}.tmp.XXXXXX")
trap 'rm -rf -- "$work_dir"' EXIT

print_summary

echo "[1/3] Preparing boot disk with external metadata..."
cp --reflink=auto --sparse=always "$BOOT_RAW" "$work_dir/boot.img"
sgdisk --change-name="${metadata_partitions[0]}:metadata-unused" "$work_dir/boot.img"
qemu-img convert -f raw -O qcow2 "$work_dir/boot.img" "$work_dir/boot.qcow2"

echo "[2/3] Creating sparse empty userdata qcow2..."
qemu-img create -f qcow2 "$work_dir/userdata.qcow2" "$USERDATA_SIZE" >/dev/null

echo "[3/3] Creating GPT metadata disk..."
# Match upstream's 32 MiB metadata partition, plus alignment and GPT overhead.
truncate -s 34M "$work_dir/metadata.img"
sgdisk --clear --new=1:2048:+32M --typecode=1:8300 \
    --change-name=1:metadata "$work_dir/metadata.img"
qemu-img convert -f raw -O qcow2 "$work_dir/metadata.img" "$work_dir/metadata.qcow2"

mv -f -- "$work_dir/boot.qcow2" "$BOOT_QCOW2"
mv -f -- "$work_dir/userdata.qcow2" "$USERDATA_QCOW2"
mv -f -- "$work_dir/metadata.qcow2" "$METADATA_QCOW2"

echo
echo "Done."
echo "Boot qcow2    : $BOOT_QCOW2"
echo "Userdata qcow2: $USERDATA_QCOW2"
echo "Metadata qcow2: $METADATA_QCOW2"
echo
echo "Suggested VM attachment order:"
echo "  - boot disk     : $BOOT_QCOW2"
echo "  - userdata disk : $USERDATA_QCOW2"
echo "  - metadata disk : $METADATA_QCOW2 (vdc, GPT partition vdc1)"
echo "Keep the deployed userdata and metadata disks together across boot image updates."
echo "The empty images are for fresh installs; migrate existing metadata before upgrading."
