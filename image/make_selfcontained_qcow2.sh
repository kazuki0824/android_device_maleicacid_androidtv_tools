#!/usr/bin/env bash
set -euo pipefail

# make_selfcontained_qcow2.v11.sh
#
# Goal:
#   Create a "preinstalled" system-disk qcow2 for LineageOS virtio_* targets so that
#   Recovery "Apply update" is no longer needed. The script:
#     - creates the expected GPT partition layout for the system disk
#     - writes super.img directly to the super partition
#     - writes boot.img to boot_a/boot_b
#     - writes vendor_boot.img to vendor_boot_a/vendor_boot_b
#     - optionally writes vbmeta.img if present
#     - seeds the EFI partition from the built installer image, then best-effort patches
#       text config files inside EFI to disable installer/recovery flags
#   A separate empty userdata qcow2 can also be created (recommended/official approach).
#
# Contract:
#   - Run from the Android repo root (directory containing .repo/)
#
# Notes:
#   - This is a best-effort "preinstalled disk" generator. It prefers built artifacts from OUT_DIR.
#   - Official LineageOS virtio install flow uses a separate userdata disk. This script can create one,
#     but it does NOT attempt to pre-format it to a device-specific Android data layout.
#   - If a normal non-installer EFI/ESP image is not available in the build outputs, this script falls
#     back to the installer ESP image and patches common config flags to avoid install/recovery mode.
#
# Usage:
#   sudo device/maleicacid/androidtv-tools/image/make_selfcontained_qcow2.v11.sh <product> [options]
#
# Options:
#   --size 18G                System disk virtual size (default: 18G)
#   --userdata-size 8G        Userdata disk virtual size (default: 8G)
#   --metadata-mib 64
#   --misc-mib 16
#   --persist-mib 256
#   --vbmeta-mib 8
#   --boot-mib 128
#   --vendor-boot-mib 128
#   --bios-mib 8
#   --nbd /dev/nbd0
#   --out <path>              System-disk qcow2 output path
#   --userdata-out <path>     Userdata qcow2 output path (default beside system image)
#   --out-base <dir>          Base dir containing target/product or nested */target/product
#   --out-dir <dir>           Product output dir (overrides search)

ARG="${1:-}"; shift || true
[[ -n "${ARG}" ]] || { echo "Usage: $0 <product> [options]" >&2; exit 1; }

PRODUCT="${ARG}"
SHORT="${ARG}"
[[ "${SHORT}" == lineage_* ]] && SHORT="${SHORT#lineage_}"
[[ "${PRODUCT}" != lineage_* ]] && PRODUCT="lineage_${PRODUCT}"

SIZE="18G"
USERDATA_SIZE="8G"
METADATA_MIB="64"
MISC_MIB="16"
PERSIST_MIB="256"
VBMETA_MIB="8"
BOOT_MIB="128"
VENDOR_BOOT_MIB="128"
BIOS_MIB="8"
NBD_DEV="/dev/nbd0"
OUT_PATH=""
USERDATA_OUT=""
OUT_BASE_OVERRIDE=""
OUT_DIR_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --size) SIZE="$2"; shift 2;;
    --userdata-size) USERDATA_SIZE="$2"; shift 2;;
    --metadata-mib) METADATA_MIB="$2"; shift 2;;
    --misc-mib) MISC_MIB="$2"; shift 2;;
    --persist-mib) PERSIST_MIB="$2"; shift 2;;
    --vbmeta-mib) VBMETA_MIB="$2"; shift 2;;
    --boot-mib) BOOT_MIB="$2"; shift 2;;
    --vendor-boot-mib) VENDOR_BOOT_MIB="$2"; shift 2;;
    --bios-mib) BIOS_MIB="$2"; shift 2;;
    --nbd) NBD_DEV="$2"; shift 2;;
    --out) OUT_PATH="$2"; shift 2;;
    --userdata-out) USERDATA_OUT="$2"; shift 2;;
    --out-base) OUT_BASE_OVERRIDE="$2"; shift 2;;
    --out-dir) OUT_DIR_OVERRIDE="$2"; shift 2;;
    *) echo "Unknown arg: $1" >&2; exit 1;;
  esac
done

find_android_top_from_pwd() {
  local d; d="$(pwd -P)"
  while [[ "${d}" != "/" ]]; do
    [[ -d "${d}/.repo" ]] && { echo "${d}"; return 0; }
    d="$(dirname "${d}")"
  done
  return 1
}

TOP="$(find_android_top_from_pwd)" || { echo "[!] Could not find Android TOP (.repo) from current working directory." >&2; exit 1; }
[[ -f "${TOP}/build/envsetup.sh" ]] || { echo "[!] build/envsetup.sh missing under ${TOP}" >&2; exit 1; }

find_product_root() {
  local base="$1"
  [[ -d "${base}/target/product" ]] && { echo "${base}/target/product"; return 0; }
  local d
  d="$(find "${base}" -maxdepth 3 -type d -path '*/target/product' -print -quit 2>/dev/null || true)"
  [[ -n "${d}" ]] && { echo "${d}"; return 0; }
  return 1
}

declare -a CANDIDATES=()
if [[ -n "${OUT_BASE_OVERRIDE}" ]]; then
  CANDIDATES+=("${OUT_BASE_OVERRIDE}")
else
  CANDIDATES+=("${TOP}/out-${PRODUCT}" "${TOP}/out")
fi

OUT_DIR=""
if [[ -n "${OUT_DIR_OVERRIDE}" ]]; then
  OUT_DIR="${OUT_DIR_OVERRIDE}"
else
  for OUT_BASE in "${CANDIDATES[@]}"; do
    if PRODUCT_ROOT="$(find_product_root "${OUT_BASE}")"; then
      HIT="$(find "${PRODUCT_ROOT}" -maxdepth 2 -type f \( -name "lineage-*-UNOFFICIAL-*${SHORT}*.img" -o -name "lineage-*-UNOFFICIAL-*${SHORT}*.zip" -o -name "boot.img" -o -name "super.img" \) -print -quit 2>/dev/null || true)"
      [[ -n "${HIT}" ]] && { OUT_DIR="$(dirname "${HIT}")"; break; }
    fi
  done
fi
[[ -n "${OUT_DIR}" && -d "${OUT_DIR}" ]] || { echo "[!] Could not determine OUT_DIR for ${PRODUCT} (short=${SHORT})" >&2; exit 1; }

# Build artifacts
INSTALL_ESP_IMG="$(find "${OUT_DIR}" -maxdepth 1 -type f -name "lineage-*-UNOFFICIAL-*${SHORT}*.img" -print -quit 2>/dev/null || true)"
[[ -n "${INSTALL_ESP_IMG}" ]] || INSTALL_ESP_IMG="$(find "${OUT_DIR}" -maxdepth 1 -type f -name "lineage-*-UNOFFICIAL-*.img" -print -quit 2>/dev/null || true)"

# Optional normal ESP/EFI artifact candidates (prefer these if present)
NORMAL_ESP_IMG=""
for cand in \
  "${OUT_DIR}/espimage.img" \
  "${OUT_DIR}/efi.img" \
  "${OUT_DIR}/bootmgr.img" \
  "${OUT_DIR}/system-esp.img" \
  ; do
  [[ -f "${cand}" ]] && { NORMAL_ESP_IMG="${cand}"; break; }
done
ESP_IMG="${NORMAL_ESP_IMG:-${INSTALL_ESP_IMG}}"

SUPER_IMG=""
for cand in \
  "${OUT_DIR}/super.img" \
  "${OUT_DIR}/obj/PACKAGING/superimage_intermediates/super.img" \
  "$(find "${OUT_DIR}/obj/PACKAGING" -maxdepth 4 -type f -name super.img -print -quit 2>/dev/null || true)" \
  ; do
  [[ -n "${cand}" && -f "${cand}" ]] && { SUPER_IMG="${cand}"; break; }
done

BOOT_IMG=""
for cand in \
  "${OUT_DIR}/boot.img" \
  "$(find "${OUT_DIR}" -maxdepth 2 -type f -name boot.img -print -quit 2>/dev/null || true)" \
  ; do
  [[ -n "${cand}" && -f "${cand}" ]] && { BOOT_IMG="${cand}"; break; }
done

VENDOR_BOOT_IMG=""
for cand in \
  "${OUT_DIR}/vendor_boot.img" \
  "$(find "${OUT_DIR}" -maxdepth 2 -type f -name vendor_boot.img -print -quit 2>/dev/null || true)" \
  ; do
  [[ -n "${cand}" && -f "${cand}" ]] && { VENDOR_BOOT_IMG="${cand}"; break; }
done

VBMETA_IMG=""
for cand in \
  "${OUT_DIR}/vbmeta.img" \
  "$(find "${OUT_DIR}" -maxdepth 2 -type f -name vbmeta.img -print -quit 2>/dev/null || true)" \
  ; do
  [[ -n "${cand}" && -f "${cand}" ]] && { VBMETA_IMG="${cand}"; break; }
done

MISC_INFO="$(find "${OUT_DIR}/obj/PACKAGING" -maxdepth 4 -type f -name misc_info.txt -print -quit 2>/dev/null || true)"

[[ -n "${ESP_IMG}" && -f "${ESP_IMG}" ]] || { echo "[!] Could not locate an ESP/EFI image (installer or normal) in ${OUT_DIR}" >&2; exit 1; }
[[ -n "${SUPER_IMG}" && -f "${SUPER_IMG}" ]] || { echo "[!] super.img not found. Build it first (e.g. make dist or locate superimage output)." >&2; exit 1; }
[[ -n "${BOOT_IMG}" && -f "${BOOT_IMG}" ]] || { echo "[!] boot.img not found in ${OUT_DIR}" >&2; exit 1; }
[[ -n "${VENDOR_BOOT_IMG}" && -f "${VENDOR_BOOT_IMG}" ]] || { echo "[!] vendor_boot.img not found in ${OUT_DIR}" >&2; exit 1; }
[[ -n "${MISC_INFO}" && -f "${MISC_INFO}" ]] || { echo "[!] misc_info.txt not found under ${OUT_DIR}/obj/PACKAGING" >&2; exit 1; }

[[ -n "${OUT_PATH}" ]] || OUT_PATH="${OUT_DIR}/androidtv-${PRODUCT}.qcow2"
[[ -n "${USERDATA_OUT}" ]] || USERDATA_OUT="${OUT_DIR}/androidtv-${PRODUCT}-userdata.qcow2"

SUPER_BYTES="$(
  awk -F= '
    $1=="super_super_device_size" {print $2; exit}
    $1=="super_partition_size"    {print $2; exit}
  ' "${MISC_INFO}" 2>/dev/null | tr -d '\r' | sed -E 's/[^0-9].*$//'
)"
[[ -n "${SUPER_BYTES}" ]] || { echo "[!] Could not parse super size from ${MISC_INFO}" >&2; exit 1; }
SUPER_MIB="$(( (SUPER_BYTES + 1024*1024 - 1) / (1024*1024) ))"

echo "[*] Product           : ${PRODUCT} (short=${SHORT})"
echo "[*] OUT_DIR           : ${OUT_DIR}"
echo "[*] ESP image         : ${ESP_IMG}"
[[ -n "${NORMAL_ESP_IMG}" ]] && echo "[*] Using normal ESP   : yes" || echo "[*] Using installer ESP: yes (will patch config best-effort)"
echo "[*] super.img         : ${SUPER_IMG}"
echo "[*] boot.img          : ${BOOT_IMG}"
echo "[*] vendor_boot.img   : ${VENDOR_BOOT_IMG}"
[[ -n "${VBMETA_IMG}" ]] && echo "[*] vbmeta.img         : ${VBMETA_IMG}" || echo "[*] vbmeta.img         : not found (partition left blank)"
echo "[*] misc_info.txt     : ${MISC_INFO}"
echo "[*] super size        : ${SUPER_BYTES} bytes (~${SUPER_MIB} MiB)"
echo "[*] system qcow2      : ${OUT_PATH}"
echo "[*] userdata qcow2    : ${USERDATA_OUT} (${USERDATA_SIZE})"

attach_nbd() {
  modprobe nbd max_part=32 || true
  qemu-nbd --disconnect "${NBD_DEV}" >/dev/null 2>&1 || true
  qemu-nbd --connect "${NBD_DEV}" "${OUT_PATH}"
  partprobe "${NBD_DEV}" || true
  sleep 1
  partprobe "${NBD_DEV}" || true
}

cleanup() {
  set +e
  sync
  umount -f /mnt/androidtv-efi 2>/dev/null || true
  qemu-nbd --disconnect "${NBD_DEV}" 2>/dev/null || true
}
trap cleanup EXIT

# Create a separate userdata disk (official guide / req 7* realistic path)
qemu-img create -f qcow2 "${USERDATA_OUT}" "${USERDATA_SIZE}" >/dev/null

# Create fresh system disk with partition order aligned to preinstall_check
qemu-img create -f qcow2 "${OUT_PATH}" "${SIZE}" >/dev/null
attach_nbd

ESP_BYTES="$(stat -c '%s' "${ESP_IMG}")"
ESP_MIB="$(( (ESP_BYTES + 1024*1024 - 1) / (1024*1024) + 1 ))"

sgdisk -og "${NBD_DEV}"
sgdisk -n "1:0:+${ESP_MIB}M"         -t "1:ef00" -c "1:EFI"           "${NBD_DEV}"
sgdisk -n "2:0:+${SUPER_MIB}M"       -t "2:8300" -c "2:super"         "${NBD_DEV}"
sgdisk -n "3:0:+${MISC_MIB}M"        -t "3:8300" -c "3:misc"          "${NBD_DEV}"
sgdisk -n "4:0:+${PERSIST_MIB}M"     -t "4:8300" -c "4:persist"       "${NBD_DEV}"
sgdisk -n "5:0:+${METADATA_MIB}M"    -t "5:8300" -c "5:metadata"      "${NBD_DEV}"
sgdisk -n "6:0:+${VBMETA_MIB}M"      -t "6:8300" -c "6:vbmeta"        "${NBD_DEV}"
sgdisk -n "7:0:+${VENDOR_BOOT_MIB}M" -t "7:8300" -c "7:vendor_boot_a" "${NBD_DEV}"
sgdisk -n "8:0:+${VENDOR_BOOT_MIB}M" -t "8:8300" -c "8:vendor_boot_b" "${NBD_DEV}"
sgdisk -n "9:0:+${BOOT_MIB}M"        -t "9:8300" -c "9:boot_a"        "${NBD_DEV}"
sgdisk -n "10:0:+${BOOT_MIB}M"       -t "10:8300" -c "10:boot_b"      "${NBD_DEV}"
sgdisk -n "11:0:+${BIOS_MIB}M"       -t "11:ef02" -c "11:BIOS"        "${NBD_DEV}"
partprobe "${NBD_DEV}" || true
sleep 1
partprobe "${NBD_DEV}" || true

# Write partition contents
echo "[*] Writing ESP image -> ${NBD_DEV}p1"
dd if="${ESP_IMG}" of="${NBD_DEV}p1" bs=4M conv=fsync,notrunc status=progress

echo "[*] Writing super.img -> ${NBD_DEV}p2"
dd if="${SUPER_IMG}" of="${NBD_DEV}p2" bs=4M conv=fsync,notrunc status=progress

echo "[*] Writing boot.img -> ${NBD_DEV}p9 and ${NBD_DEV}p10"
dd if="${BOOT_IMG}" of="${NBD_DEV}p9"  bs=4M conv=fsync,notrunc status=progress
dd if="${BOOT_IMG}" of="${NBD_DEV}p10" bs=4M conv=fsync,notrunc status=progress

echo "[*] Writing vendor_boot.img -> ${NBD_DEV}p7 and ${NBD_DEV}p8"
dd if="${VENDOR_BOOT_IMG}" of="${NBD_DEV}p7" bs=4M conv=fsync,notrunc status=progress
dd if="${VENDOR_BOOT_IMG}" of="${NBD_DEV}p8" bs=4M conv=fsync,notrunc status=progress

if [[ -n "${VBMETA_IMG}" && -f "${VBMETA_IMG}" ]]; then
  echo "[*] Writing vbmeta.img -> ${NBD_DEV}p6"
  dd if="${VBMETA_IMG}" of="${NBD_DEV}p6" bs=1M conv=fsync,notrunc status=progress
fi

# Best-effort patch: if we used installer ESP, remove common install/recovery flags in text configs.
if [[ -z "${NORMAL_ESP_IMG}" ]]; then
  mkdir -p /mnt/androidtv-efi
  if mount "${NBD_DEV}p1" /mnt/androidtv-efi; then
    echo "[*] Patching EFI text configs to disable install/recovery flags (best-effort)"
    while IFS= read -r -d '' f; do
      sed -i \
        -e 's/[[:space:]]\+androidboot\.install=1//g' \
        -e 's/[[:space:]]\+ro\.boot\.install=1//g' \
        -e 's/[[:space:]]\+androidboot\.force_recovery=1//g' \
        -e 's/[[:space:]]\+androidboot\.mode=recovery//g' \
        -e 's/[[:space:]]\+bootmode=recovery//g' \
        -e 's/[[:space:]]\+recovery//g' \
        "$f" || true
    done < <(find /mnt/androidtv-efi -type f \( -name '*.cfg' -o -name '*.conf' -o -name '*.lst' -o -name '*.cmdline' \) -print0 2>/dev/null)
    sync
    umount /mnt/androidtv-efi || true
  else
    echo "[!] Warning: could not mount EFI partition for patching; continuing with unpatched ESP."
  fi
fi

qemu-nbd --disconnect "${NBD_DEV}"
trap - EXIT

echo
echo "============================================================"
echo "[OK] Preinstalled system-disk qcow2 created:"
echo "     ${OUT_PATH}"
echo "[OK] Empty userdata qcow2 created:"
echo "     ${USERDATA_OUT}"
echo
echo "Recommended virt-install:"
echo "  virt-install ... \\"
echo "    --disk path=${OUT_PATH},format=qcow2,bus=virtio,serial=sd \\"
echo "    --disk path=${USERDATA_OUT},format=qcow2,bus=virtio,serial=ud"
echo
echo "If first boot still enters Recovery, do ONLY:"
echo "  Factory reset -> Format data/factory reset"
echo "Then reboot. 'Apply update' should not be needed."
echo "============================================================"
