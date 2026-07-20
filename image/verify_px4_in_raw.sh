#!/usr/bin/env bash
set -euo pipefail

PRODUCT="${1:-virtio_x86_64_tv_grub}"
PRODUCT_OUT="out/target/product/${PRODUCT}"
RAW_IMAGE="${PRODUCT_OUT}/disk-vda.img"

if [[ ! -d .repo ]]; then
    echo "ERROR: run from the Android build root containing .repo" >&2
    exit 1
fi

if [[ ! -f "${RAW_IMAGE}" ]]; then
    echo "ERROR: raw disk image not found: ${RAW_IMAGE}" >&2
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
raw_image="${product_out}/disk-vda.img"
host_bin="/workspace/out/host/linux-x86/bin"

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

for command in sfdisk dd debugfs file find python3; do
    command -v "${command}" >/dev/null 2>&1 || fail "required command is unavailable: ${command}"
done

lpunpack="${host_bin}/lpunpack"
[[ -x "${lpunpack}" ]] || fail "lpunpack is unavailable: ${lpunpack}"
[[ -f "${raw_image}" ]] || fail "raw disk image is missing: ${raw_image}"

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

partition_info="$({ sfdisk --json "${raw_image}"; } | python3 -c '
import json
import sys

table = json.load(sys.stdin)["partitiontable"]
parts = table.get("partitions", [])
super_part = next((p for p in parts if p.get("name") == "super"), None)
if super_part is None:
    super_part = next((p for p in parts if str(p.get("name", "")).startswith("super")), None)
if super_part is None:
    raise SystemExit("super partition was not found in raw disk image")

print(super_part["start"], super_part["size"], table.get("sectorsize", 512))
')" || fail "unable to locate super partition in raw disk image"

read -r super_start super_sectors sector_size <<<"${partition_info}"
super_image="${tmpdir}/super.img"

echo "Extracting super partition from raw disk image..."
dd if="${raw_image}" of="${super_image}" \
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

    modules_dir="${tmpdir}/modules/${partition_name}"
    mkdir -p "${modules_dir}"

    if ! debugfs -R "rdump /lib/modules ${modules_dir}" "${partition_image}" >/dev/null 2>&1; then
        echo "Unable to inspect ${partition_name}: $(file -b "${partition_image}")" >&2
        continue
    fi

    module_path="$(find "${modules_dir}" -type f -name 'px4_drv.ko*' -print -quit)"
    if [[ -n "${module_path}" ]]; then
        found="${partition_name}:${module_path#${modules_dir}}"
        break
    fi
done < <(find "${logical_dir}" -maxdepth 1 -type f -name '*.img' -print | sort)

[[ -n "${found}" ]] || fail \
    "px4_drv.ko is absent from vendor/vendor_dlkm inside raw disk image ${raw_image}"

echo "Verified raw disk image contains ${found}"
VERIFY
