#!/usr/bin/env bash
set -euo pipefail

PRODUCT="${1:-virtio_x86_64_tv_grub}"
PRODUCT_OUT="out/target/product/${PRODUCT}"
QCOW2_IMAGE="${PRODUCT_OUT}/disk-vda.qcow2"

if [[ ! -d .repo ]]; then
    echo "ERROR: run from the Android build root containing .repo" >&2
    exit 1
fi

if [[ ! -f "${QCOW2_IMAGE}" ]]; then
    echo "ERROR: final qcow2 image not found: ${QCOW2_IMAGE}" >&2
    exit 1
fi

sudo docker run --rm -i \
    --mount "type=bind,src=$(pwd -P),dst=/workspace" \
    -w /workspace \
    aosp-build \
    bash -s -- "${PRODUCT}" <<'VERIFY'
set -euo pipefail

product="$1"
product_out="/workspace/out/target/product/${product}"
qcow2_image="${product_out}/disk-vda.qcow2"
host_bin="/workspace/out/host/linux-x86/bin"

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

for command in qemu-img sfdisk dd debugfs file python3; do
    command -v "${command}" >/dev/null 2>&1 || fail "required command is unavailable: ${command}"
done

lpunpack="${host_bin}/lpunpack"
[[ -x "${lpunpack}" ]] || fail "lpunpack is unavailable: ${lpunpack}"
[[ -f "${qcow2_image}" ]] || fail "final qcow2 image is missing: ${qcow2_image}"

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

raw_disk="${tmpdir}/disk-vda.raw"
echo "Converting final qcow2 to raw for inspection..."
qemu-img convert -f qcow2 -O raw "${qcow2_image}" "${raw_disk}"

partition_info="$({ sfdisk --json "${raw_disk}"; } | python3 -c '
import json
import sys

table = json.load(sys.stdin)["partitiontable"]
parts = table.get("partitions", [])
super_part = next((p for p in parts if p.get("name") == "super"), None)
if super_part is None:
    super_part = next((p for p in parts if str(p.get("name", "")).startswith("super")), None)
if super_part is None:
    raise SystemExit("super partition was not found in final qcow2")

print(super_part["start"], super_part["size"], table.get("sectorsize", 512))
')" || fail "unable to locate super partition in final qcow2"

read -r super_start super_sectors sector_size <<<"${partition_info}"
super_image="${tmpdir}/super.img"

echo "Extracting super partition from final qcow2..."
dd if="${raw_disk}" of="${super_image}" \
    bs="${sector_size}" skip="${super_start}" count="${super_sectors}" status=none

logical_dir="${tmpdir}/logical"
mkdir -p "${logical_dir}"
"${lpunpack}" "${super_image}" "${logical_dir}"

found=""
while IFS= read -r partition_image; do
    partition_name="$(basename "${partition_image}" .img)"
    case "${partition_name}" in
        vendor|vendor_a|vendor_b|vendor_dlkm|vendor_dlkm_a|vendor_dlkm_b)
            ;;
        *)
            continue
            ;;
    esac

    if ! file "${partition_image}" | grep -qi 'ext[234] filesystem'; then
        echo "Skipping non-ext partition image: ${partition_name}" >&2
        continue
    fi

    if debugfs -R 'stat /lib/modules/px4_drv.ko' "${partition_image}" 2>/dev/null \
        | grep -q '^Inode:'; then
        found="${partition_name}:/lib/modules/px4_drv.ko"
        break
    fi

done < <(find "${logical_dir}" -maxdepth 1 -type f -name '*.img' -print | sort)

[[ -n "${found}" ]] || fail \
    "px4_drv.ko is absent from vendor/vendor_dlkm inside final image ${qcow2_image}"

echo "Verified final image contains ${found}"
VERIFY
