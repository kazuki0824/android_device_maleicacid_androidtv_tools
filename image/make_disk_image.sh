#!/usr/bin/env bash
set -euo pipefail
# Convert a build-time prepared boot disk and provision independent writable
# state disk seeds, WITHOUT overwriting any existing state.
usage() {
  cat <<'USAGE'
Usage: make_disk_image.sh [--product-out PATH] [--boot-raw PATH]
                          [--boot-qcow2 PATH] [--userdata-qcow2 PATH]
                          [--metadata-qcow2 PATH] [--persist-qcow2 PATH]
                          [--userdata-size SIZE]
The boot image is refreshed on each invocation. Existing state images are
never overwritten. For an intentional reset, delete the affected image
explicitly while the VM is stopped and after taking a backup.
USAGE
}
PRODUCT_OUT="out/target/product/virtio_x86_64_tv_grub"
BOOT_RAW=""
BOOT_QCOW2=""
USERDATA_QCOW2=""
METADATA_QCOW2=""
PERSIST_QCOW2=""
USERDATA_SIZE="16G"
while (($#)); do
  case "$1" in
    --product-out) PRODUCT_OUT="$2"; shift 2;;
    --boot-raw) BOOT_RAW="$2"; shift 2;;
    --boot-qcow2) BOOT_QCOW2="$2"; shift 2;;
    --userdata-qcow2) USERDATA_QCOW2="$2"; shift 2;;
    --metadata-qcow2) METADATA_QCOW2="$2"; shift 2;;
    --persist-qcow2) PERSIST_QCOW2="$2"; shift 2;;
    --userdata-size) USERDATA_SIZE="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    --force) echo "ERROR: --force has been removed to protect persistent state" >&2; exit 2;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2;;
  esac
done
[[ -d .repo ]] || { echo "ERROR: run from Android build root" >&2; exit 1; }
command -v qemu-img >/dev/null
command -v sgdisk >/dev/null
BOOT_RAW="${BOOT_RAW:-$PRODUCT_OUT/disk-vda.img}"
BOOT_QCOW2="${BOOT_QCOW2:-$PRODUCT_OUT/disk-vda.qcow2}"
USERDATA_QCOW2="${USERDATA_QCOW2:-$PRODUCT_OUT/userdata-empty.qcow2}"
METADATA_QCOW2="${METADATA_QCOW2:-$PRODUCT_OUT/metadata-empty.qcow2}"
PERSIST_QCOW2="${PERSIST_QCOW2:-$PRODUCT_OUT/persist-initial.qcow2}"
for input in "$BOOT_RAW" "$PRODUCT_OUT/persist.img" "$PRODUCT_OUT/EFI.img" \
  "$PRODUCT_OUT/super.img" "$PRODUCT_OUT/boot.img" \
  "$PRODUCT_OUT/vendor_boot.img" "$PRODUCT_OUT/BIOS.img" "$PRODUCT_OUT/MBR.img"; do
  [[ -s "$input" ]] || { echo "ERROR: missing input $input" >&2; exit 1; }
done
declare -A distinct_paths=()
for name in "$BOOT_RAW" "$BOOT_QCOW2" "$USERDATA_QCOW2" "$METADATA_QCOW2" "$PERSIST_QCOW2"; do
  canonical=$(realpath -m "$name")
  [[ ! -v distinct_paths[$canonical] ]] || { echo "ERROR: aliasing paths: $name" >&2; exit 1; }
  distinct_paths[$canonical]=1
done
# Fail closed if the build-time GPT has not already disabled both legacy slots.
partition_names=$(sgdisk --print "$BOOT_RAW")
grep -Eq 'persist-unused$' <<< "$partition_names"
grep -Eq 'metadata-unused$' <<< "$partition_names"
! grep -Eq '[[:space:]]persist$' <<< "$partition_names"
! grep -Eq '[[:space:]]metadata$' <<< "$partition_names"

for name in "$BOOT_QCOW2" "$USERDATA_QCOW2" "$METADATA_QCOW2" "$PERSIST_QCOW2"; do
  mkdir -p "$(dirname "$name")"
done

# Work in the destination's directory so mv is an atomic replacement.
tmp_boot=$(mktemp "${BOOT_QCOW2}.tmp.XXXXXX")
trap 'rm -f -- "$tmp_boot"' EXIT
qemu-img convert -f raw -O qcow2 "$BOOT_RAW" "$tmp_boot"
mv -f -- "$tmp_boot" "$BOOT_QCOW2"

create_seed() {
  local output=$1 kind=$2 tmpdir
  if [[ -e "$output" ]]; then
    echo "KEEP: $output"
    return 0
  fi
  tmpdir=$(mktemp -d "$(dirname "$output")/.seed.XXXXXXXX")
  case "$kind" in
    userdata)
      qemu-img create -f qcow2 "$tmpdir/seed.qcow2" "$USERDATA_SIZE" >/dev/null;;
    metadata)
      truncate -s 34M "$tmpdir/metadata.img"
      sgdisk --clear --new=1:2048:+32M --typecode=1:8300 \
        --change-name=1:metadata "$tmpdir/metadata.img" >/dev/null
      qemu-img convert -f raw -O qcow2 "$tmpdir/metadata.img" "$tmpdir/seed.qcow2";;
    persist)
      qemu-img convert -f raw -O qcow2 "$PRODUCT_OUT/persist.img" "$tmpdir/seed.qcow2";;
  esac
  if [[ -e "$output" ]]; then
    echo "KEEP: concurrent seed appeared: $output"
  else
    # noclobber atomic install; no --force nor existing-state overwrite
    mv -n -- "$tmpdir/seed.qcow2" "$output"
    echo "CREATE: $output"
  fi
  rm -rf -- "$tmpdir"
}
create_seed "$USERDATA_QCOW2" userdata
create_seed "$METADATA_QCOW2" metadata
create_seed "$PERSIST_QCOW2" persist
echo "Attach as vda: $BOOT_QCOW2"
echo "Attach as vdb: $USERDATA_QCOW2"
echo "Attach as vdc (GPT metadata at vdc1): $METADATA_QCOW2"
echo "Attach as vdd (whole-disk FAT32 PERSIST): $PERSIST_QCOW2"
