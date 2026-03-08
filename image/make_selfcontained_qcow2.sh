#!/usr/bin/env bash
set -euo pipefail

# make_selfcontained_qcow2.v2.sh
# - Locates OUT_DIR by searching under an OUT_BASE that contains target/product/<device>/...
# - Supports separated OUT_DIR_COMMON_BASE (e.g., out-<product>).
#
# Usage:
#   sudo device/maleicacid/androidtv-tools/image/make_selfcontained_qcow2.v2.sh <product> [options]
#
# Options:
#   --out-base <dir>    Base directory that contains target/product (default: auto: out-<product>, out)
#   --out-dir <dir>     Directory that contains produced .img/.zip (overrides search)
#   --size 32G
#   --install-mib 2048
#   --nbd /dev/nbd0
#   --out <path>

ARG="${1:-}"
shift || true
if [[ -z "${ARG}" ]]; then
  echo "Usage: $0 <r86s_tv_virtio|qemu_tv_virtio|lineage_r86s_tv_virtio|lineage_qemu_tv_virtio> [--out-base dir] [--out-dir dir] [--size 32G] [--install-mib 2048] [--nbd /dev/nbd0] [--out path]" >&2
  exit 1
fi

PRODUCT="${ARG}"
if [[ "${PRODUCT}" != lineage_* ]]; then
  PRODUCT="lineage_${PRODUCT}"
fi

SIZE="32G"
INSTALL_MIB="2048"
NBD_DEV="/dev/nbd0"
OUT_PATH=""
OUT_BASE_OVERRIDE=""
OUT_DIR_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --size) SIZE="$2"; shift 2;;
    --install-mib) INSTALL_MIB="$2"; shift 2;;
    --nbd) NBD_DEV="$2"; shift 2;;
    --out) OUT_PATH="$2"; shift 2;;
    --out-base) OUT_BASE_OVERRIDE="$2"; shift 2;;
    --out-dir) OUT_DIR_OVERRIDE="$2"; shift 2;;
    *) echo "Unknown arg: $1" >&2; exit 1;;
  esac
done

find_android_top() {
  local d
  d="$(cd "$(dirname "$0")" && pwd)"
  while [[ "${d}" != "/" ]]; do
    if [[ -f "${d}/build/envsetup.sh" ]]; then
      echo "${d}"
      return 0
    fi
    d="$(dirname "${d}")"
  done
  return 1
}

TOP="$(find_android_top)" || {
  echo "[!] Could not find Android TOP (build/envsetup.sh). Run inside the repo-synced tree." >&2
  exit 1
}

declare -a CANDIDATES=()
if [[ -n "${OUT_BASE_OVERRIDE}" ]]; then
  CANDIDATES+=("${OUT_BASE_OVERRIDE}")
else
  CANDIDATES+=("${TOP}/out-${PRODUCT}")
  CANDIDATES+=("${TOP}/out")
fi

OUT_DIR=""
if [[ -n "${OUT_DIR_OVERRIDE}" ]]; then
  OUT_DIR="${OUT_DIR_OVERRIDE}"
else
  for OUT_BASE in "${CANDIDATES[@]}"; do
    if [[ -d "${OUT_BASE}/target/product" ]]; then
      OTA_ZIP="$(find "${OUT_BASE}/target/product" -maxdepth 2 -type f -name "${PRODUCT}*-ota.zip" -print -quit 2>/dev/null || true)"
      if [[ -n "${OTA_ZIP}" ]]; then
        OUT_DIR="$(dirname "${OTA_ZIP}")"
        break
      fi
      UNOFF_ZIP="$(find "${OUT_BASE}/target/product" -maxdepth 2 -type f -name "lineage-*-UNOFFICIAL-*.zip" -print -quit 2>/dev/null || true)"
      if [[ -n "${UNOFF_ZIP}" ]]; then
        OUT_DIR="$(dirname "${UNOFF_ZIP}")"
        break
      fi
      IMG="$(find "${OUT_BASE}/target/product" -maxdepth 2 -type f -name "lineage-*-UNOFFICIAL-*.img" -print -quit 2>/dev/null || true)"
      if [[ -n "${IMG}" ]]; then
        OUT_DIR="$(dirname "${IMG}")"
        break
      fi
    fi
  done
fi

if [[ -z "${OUT_DIR}" || ! -d "${OUT_DIR}" ]]; then
  echo "[!] Could not determine OUT_DIR for product: ${PRODUCT}" >&2
  echo "    Tried OUT_BASE candidates:" >&2
  for c in "${CANDIDATES[@]}"; do
    echo "      - ${c}" >&2
  done
  echo "    Hint: pass --out-base <dir> (contains target/product) or --out-dir <dir> (contains .img/.zip)" >&2
  exit 1
fi

INSTALL_IMG="$(find "${OUT_DIR}" -maxdepth 1 -type f -name "lineage-*-UNOFFICIAL-*.img" -print -quit 2>/dev/null || true)"
FLASH_ZIP="$(find "${OUT_DIR}" -maxdepth 1 -type f -name "lineage-*-UNOFFICIAL-*.zip" -print -quit 2>/dev/null || true)"
if [[ -z "${FLASH_ZIP}" ]]; then
  FLASH_ZIP="$(find "${OUT_DIR}" -maxdepth 1 -type f -name "${PRODUCT}*-ota.zip" -print -quit 2>/dev/null || true)"
fi

if [[ -z "${INSTALL_IMG}" ]]; then
  echo "[!] espimage-install output not found in: ${OUT_DIR}" >&2
  exit 1
fi
if [[ -z "${FLASH_ZIP}" ]]; then
  echo "[!] flashable zip not found in: ${OUT_DIR}" >&2
  exit 1
fi

if [[ -z "${OUT_PATH}" ]]; then
  OUT_PATH="${OUT_DIR}/androidtv-${PRODUCT}.qcow2"
fi

echo "[*] Product         : ${PRODUCT}"
echo "[*] OUT_DIR         : ${OUT_DIR}"
echo "[*] Installer image : ${INSTALL_IMG}"
echo "[*] Flashable zip   : ${FLASH_ZIP}"
echo "[*] Output qcow2    : ${OUT_PATH}"
echo "[*] Virtual size    : ${SIZE}"
echo "[*] INSTALL size    : ${INSTALL_MIB} MiB"

qemu-img convert -f raw -O qcow2 "${INSTALL_IMG}" "${OUT_PATH}"
qemu-img resize "${OUT_PATH}" "${SIZE}"

modprobe nbd max_part=32 || true
qemu-nbd --disconnect "${NBD_DEV}" >/dev/null 2>&1 || true
qemu-nbd --connect "${NBD_DEV}" "${OUT_PATH}"
trap 'set +e; sync; umount -f /mnt/androidtv-install 2>/dev/null || true; qemu-nbd --disconnect "${NBD_DEV}" 2>/dev/null || true' EXIT

partprobe "${NBD_DEV}" || true
sleep 1
partprobe "${NBD_DEV}" || true

sgdisk -n "0:0:+${INSTALL_MIB}M" -t "0:0700" -c "0:INSTALL" "${NBD_DEV}"
partprobe "${NBD_DEV}" || true
sleep 1

LASTP="$(ls -1 "${NBD_DEV}"p* | sed -E 's/.*p([0-9]+)/\1/' | sort -n | tail -n1)"
INSTALL_PART="${NBD_DEV}p${LASTP}"
echo "[*] INSTALL partition: ${INSTALL_PART}"

mkfs.vfat -F 32 -n INSTALL "${INSTALL_PART}"

mkdir -p /mnt/androidtv-install
mount "${INSTALL_PART}" /mnt/androidtv-install
cp -v "${FLASH_ZIP}" /mnt/androidtv-install/
sync
umount /mnt/androidtv-install

qemu-nbd --disconnect "${NBD_DEV}"
trap - EXIT

echo ""
echo "============================================================"
echo "[OK] Self-contained qcow2 created:"
echo "     ${OUT_PATH}"
echo "============================================================"
