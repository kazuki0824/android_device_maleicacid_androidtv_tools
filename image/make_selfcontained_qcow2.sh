#!/usr/bin/env bash
set -euo pipefail

# make_selfcontained_qcow2.v3.sh
#
# Fixes vs older versions:
# 1) OUT_DIR discovery works with OUT_DIR_COMMON_BASE separation (out-<product>) AND with nested
#    layouts (some builds place outputs under OUT_DIR_COMMON_BASE/<topname>/target/product/...).
# 2) Supports both GPT and MBR (dos) installer images:
#    - GPT: use sgdisk to add INSTALL partition
#    - MBR: use sfdisk to append a FAT32 partition at the end
#
# Usage:
#   sudo make_selfcontained_qcow2.v3.sh <product> [options]
#
# <product> may be:
#   lineage_r86s_tv_virtio / lineage_qemu_tv_virtio  (recommended)
#   r86s_tv_virtio / qemu_tv_virtio                  (will be normalized to lineage_<name>)
#
# Options:
#   --out-base <dir>    Base directory that contains (or contains */) target/product (default: auto)
#   --out-dir <dir>     Directory that contains the produced .img/.zip (overrides search)
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
  echo "[!] Could not find Android TOP (build/envsetup.sh)." >&2
  exit 1
}

find_product_root() {
  local base="$1"
  if [[ -d "${base}/target/product" ]]; then
    echo "${base}/target/product"
    return 0
  fi
  local d
  d="$(find "${base}" -maxdepth 2 -type d -path '*/target/product' -print -quit 2>/dev/null || true)"
  if [[ -n "${d}" ]]; then
    echo "${d}"
    return 0
  fi
  return 1
}

declare -a CANDIDATES=()
if [[ -n "${OUT_BASE_OVERRIDE}" ]]; then
  CANDIDATES+=("${OUT_BASE_OVERRIDE}")
else
  CANDIDATES+=("${TOP}/out-${PRODUCT}")
  CANDIDATES+=("${TOP}/out")
fi

OUT_DIR=""
PRODUCT_ROOT=""
if [[ -n "${OUT_DIR_OVERRIDE}" ]]; then
  OUT_DIR="${OUT_DIR_OVERRIDE}"
else
  for OUT_BASE in "${CANDIDATES[@]}"; do
    if PRODUCT_ROOT="$(find_product_root "${OUT_BASE}")"; then
      OTA_ZIP="$(find "${PRODUCT_ROOT}" -maxdepth 2 -type f -name "${PRODUCT}*-ota.zip" -print -quit 2>/dev/null || true)"
      if [[ -n "${OTA_ZIP}" ]]; then
        OUT_DIR="$(dirname "${OTA_ZIP}")"
        break
      fi
      UNOFF_ZIP="$(find "${PRODUCT_ROOT}" -maxdepth 2 -type f -name "lineage-*-UNOFFICIAL-*.zip" -print -quit 2>/dev/null || true)"
      if [[ -n "${UNOFF_ZIP}" ]]; then
        OUT_DIR="$(dirname "${UNOFF_ZIP}")"
        break
      fi
      IMG="$(find "${PRODUCT_ROOT}" -maxdepth 2 -type f -name "lineage-*-UNOFFICIAL-*.img" -print -quit 2>/dev/null || true)"
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
  echo "    Hint: pass --out-base <dir> or --out-dir <dir>" >&2
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

PTTYPE="$(lsblk -no PTTYPE "${NBD_DEV}" 2>/dev/null | head -n1 || true)"
SECTOR_SIZE="$(blockdev --getss "${NBD_DEV}")"
ALIGN_SECTORS="$(( (1024*1024) / SECTOR_SIZE ))"
INSTALL_SECTORS="$(( (INSTALL_MIB*1024*1024) / SECTOR_SIZE ))"

echo "[*] Partition table : ${PTTYPE:-<unknown>} (sector_size=${SECTOR_SIZE})"

if [[ "${PTTYPE}" == "gpt" ]]; then
  sgdisk -n "0:0:+${INSTALL_MIB}M" -t "0:0700" -c "0:INSTALL" "${NBD_DEV}"
else
  LAST_END="$(
    sfdisk -d "${NBD_DEV}" 2>/dev/null | awk '
      /^\/dev\// {
        start=""; size=""
        for (i=1; i<=NF; i++) {
          gsub(/,/, "", $i)
          if ($i ~ /^start=/) { split($i,a,"="); start=a[2] }
          if ($i ~ /^size=/)  { split($i,b,"="); size=b[2]  }
        }
        if (start != "" && size != "") {
          end = start + size
          if (end > max) max = end
        }
      }
      END { if (max=="") max=0; print max }
    '
  )"
  START_SECTOR="$(( ( (LAST_END + ALIGN_SECTORS - 1) / ALIGN_SECTORS ) * ALIGN_SECTORS ))"
  echo "[*] MBR last_end=${LAST_END} -> new_start=${START_SECTOR} (align=${ALIGN_SECTORS} sectors), new_size=${INSTALL_SECTORS} sectors"
  printf 'start=%s,size=%s,type=c\n' "${START_SECTOR}" "${INSTALL_SECTORS}" | sfdisk --append "${NBD_DEV}" >/dev/null
fi

partprobe "${NBD_DEV}" || true
sleep 1
partprobe "${NBD_DEV}" || true

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
