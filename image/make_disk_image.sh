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
  Existing boot image is replaced; existing userdata and metadata are preserved.
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

# Reject aliases before a boot replacement or seed creation can overwrite inputs.
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

# Existing state outputs must be regular files; valid symlinks to regular
# image files are allowed and never replaced.
check_state_path() {
    local output="$1"
    if [[ -e "$output" || -L "$output" ]]; then
        if [[ ! -f "$output" ]]; then
            echo "ERROR: state path is not an existing regular file: $output" >&2
            return 1
        fi
    fi
}
check_state_path "$USERDATA_QCOW2"
check_state_path "$METADATA_QCOW2"

# With keydirectory=/metadata/vold/metadata_encryption, a used userdata
# disk must not be paired with a freshly blank metadata disk (or vice versa).
# Only the previously impossible one-sided-success path is rejected.
if [[ -e "$USERDATA_QCOW2" && ! -e "$METADATA_QCOW2" ]] ||
   [[ ! -e "$USERDATA_QCOW2" && -e "$METADATA_QCOW2" ]]; then
    echo "ERROR: userdata/metadata images must both exist or both be absent" >&2
    exit 1
fi

# Unlike state outputs, boot is replaced; reject *all* symlinks to avoid
# an ambiguous choice between replacing a symlink and its target.
check_boot_output() {
    if [[ -L "$BOOT_QCOW2" ||
          ( -e "$BOOT_QCOW2" && ! -f "$BOOT_QCOW2" ) ]]; then
        echo "ERROR: boot output is not a regular file or is a symlink: $BOOT_QCOW2" >&2
        return 1
    fi
}
check_boot_output

# Put boot staging on its destination filesystem, and publish it last.
work_dir=$(mktemp -d "${BOOT_QCOW2}.tmp.XXXXXX")
userdata_stage=""
metadata_stage=""
trap 'rm -rf -- "$work_dir" "${userdata_stage:-}" "${metadata_stage:-}"' EXIT

print_summary

echo "[1/3] Preparing updated boot qcow2 with external metadata..."
# Only the GPT partition named metadata is renamed in the output copy;
# PERSIST stays at its original position, including for non-A/B layouts.
cp --reflink=auto --sparse=always "$BOOT_RAW" "$work_dir/boot.img"
sgdisk --change-name="${metadata_partitions[0]}:metadata-unused" "$work_dir/boot.img"
qemu-img convert -f raw -O qcow2 "$work_dir/boot.img" "$work_dir/boot.qcow2"

if [[ -e "$USERDATA_QCOW2" ]]; then
    echo "KEEP: $USERDATA_QCOW2 and $METADATA_QCOW2 (existing state pair)"
else
    # Both are absent (as validated above); concurrent builds are unsupported.
    # Complete both seeds before publishing either to its final path.
    echo "[2/3] Creating userdata seed..."
    userdata_stage=$(mktemp -d "${USERDATA_QCOW2}.tmp.XXXXXX")
    qemu-img create -f qcow2 "$userdata_stage/seed.qcow2" "$USERDATA_SIZE" >/dev/null

    echo "[3/3] Creating GPT metadata seed..."
    metadata_stage=$(mktemp -d "${METADATA_QCOW2}.tmp.XXXXXX")
    truncate -s 34M "$metadata_stage/metadata.img"
    sgdisk --clear --new=1:2048:+32M --typecode=1:8300 \
        --change-name=1:metadata "$metadata_stage/metadata.img"
    qemu-img convert -f raw -O qcow2 \
        "$metadata_stage/metadata.img" "$metadata_stage/seed.qcow2"

    # The two final paths are absent. ln -T publishes without clobbering
    # unexpected files. A failed publication aborts; no generic rollback.
    ln -T -- "$userdata_stage/seed.qcow2" "$USERDATA_QCOW2"
    ln -T -- "$metadata_stage/seed.qcow2" "$METADATA_QCOW2"
fi

# The only replace operation is for the system disk; GNU mv -T avoids
# interpreting an unexpected destination directory as a parent path.
check_boot_output
mv -fT -- "$work_dir/boot.qcow2" "$BOOT_QCOW2"

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
