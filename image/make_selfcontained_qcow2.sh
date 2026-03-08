#!/usr/bin/env bash
set -euo pipefail

# make_selfcontained_qcow2.sh (fixed)
#
# Create ONE qcow2 file which contains:
#   - a bootable installer environment (from espimage-install .img)
#   - an INSTALL volume (FAT) holding a flashable zip
#
# Key fix:
# - Android build outputs are usually under out/target/product/<TARGET_DEVICE>/ (not PRODUCT_NAME),
#   so we locate OUT_DIR by searching for produced files under out/target/product/*.
#
# Usage:
#   sudo make_selfcontained_qcow2.sh <product>
#     <product> may be r86s_tv_virtio / qemu_tv_virtio / lineage_r86s_tv_virtio / lineage_qemu_tv_virtio
#
# Options:
#   --size 32G          Total virtual size for qcow2 (default: 32G)
#   --install-mib 2048  Size of INSTALL partition (default: 2048 MiB)
#   --nbd /dev/nbd0     Which NBD device to use (default: /dev/nbd0)
#   --out <path>        Output qcow2 path (default: <OUT_DIR>/androidtv-<product>.qcow2)
#   --out-dir <path>    Override OUT_DIR (directory containing the produced .img/.zip)

ARG="${1:-}"
shift || true
if [[ -z "${ARG}" ]]; then
  echo "Usage: $0 <r86s_tv_virtio|qemu_tv_virtio|lineage_r86s_tv_virtio|lineage_qemu_tv_virtio> [--size 32G] [--install-mib 2048] [--nbd /dev/nbd0] [--out path] [--out-dir path]" >&2
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
OUT_DIR_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --size) SIZE="$2"; shift 2;;
    --install-mib) INSTALL_MIB="$2"; shift 2;;
    --nbd) NBD_DEV="$2"; shift 2;;
    --out) OUT_PATH="$2"; shift 2;;
    --out-dir) OUT_DIR_OVERRIDE="$2"; shift 2;;
    *) echo "Unknown arg: $1" >&2; exit 1;;
  esac
done

TOP="$(cd "$(dirname "$0")/../.." && pwd)"
OUT_BASE="${TOP}/out/target/product"

if [[ ! -d "${OUT_BASE}" ]]; then
  echo "[!] OUT_BASE not found: ${OUT_BASE}" >&2
  exit 1
fi

OUT_DIR=""
if [[ -n "${OUT_DIR_OVERRIDE}" ]]; then
  OUT_DIR="${OUT_DIR_OVERRIDE}"
else
  # Prefer otapackage output: <product>*-ota.zip (often written under <TARGET_DEVICE>/)
  OTA_ZIP="$(find "${OUT_BASE}" -maxdepth 2 -type f -name "${PRODUCT}*-ota.zip" -print -quit 2>/dev/null || true)"
  if [[ -n "${OTA_ZIP}" ]]; then
    OUT_DIR="$(dirname "${OTA_ZIP}")"
  else
    # fallback: if a dir named after PRODUCT exists
    if [[ -d "${OUT_BASE}/${PRODUCT}" ]]; then
      OUT_DIR="${OUT_BASE}/${PRODUCT}"
    fi
  fi
fi

if [[ -z "${OUT_DIR}" || ! -d "${OUT_DIR}" ]]; then
  echo "[!] Could not determine OUT_DIR for product: ${PRODUCT}" >&2
  echo "    Searched for: ${PRODUCT}*-ota.zip under ${OUT_BASE}" >&2
  echo "    You can pass: --out-dir <out/target/product/<device>>" >&2
  exit 1
fi

# Prefer recovery-installable zip (bacon) if present; otherwise use *-ota.zip.
FLASH_ZIP="$(find "${OUT_DIR}" -maxdepth 1 -type f -name "lineage-*-UNOFFICIAL-*.zip" -print -quit 2>/dev/null || true)"
if [[ -z "${FLASH_ZIP}" ]]; then
  FLASH_ZIP="$(find "${OUT_DIR}" -maxdepth 1 -type f -name "${PRODUCT}*-ota.zip" -print -quit 2>/dev/null || true)"
fi

# espimage-install output (device-suffixed in many trees)
INSTALL_IMG="$(find "${OUT_DIR}" -maxdepth 1 -type f -name "lineage-*-UNOFFICIAL-*.img" -print -quit 2>/dev/null || true)"

if [[ -z "${INSTALL_IMG}" ]]; then
  echo "[!] espimage-install output not found in: ${OUT_DIR}" >&2
  echo "    Expected: lineage-*-UNOFFICIAL-*.img" >&2
  exit 1
fi
if [[ -z "${FLASH_ZIP}" ]]; then
  echo "[!] flashable zip not found in: ${OUT_DIR}" >&2
  echo "    Expected one of:" >&2
  echo "      - lineage-*-UNOFFICIAL-*.zip (preferred)" >&2
  echo "      - ${PRODUCT}*-ota.zip (fallback)" >&2
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
