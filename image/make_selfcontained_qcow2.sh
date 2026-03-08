#!/usr/bin/env bash
set -euo pipefail

# requirement 7* helper:
# Create ONE qcow2 file which contains:
#   - a bootable installer environment (from espimage-install .img)
#   - an INSTALL volume (FAT) holding the flashable zip
#
# Goal:
#   User receives ONLY this qcow2, boots it once, installs via Recovery:
#     Apply update -> Choose INSTALL -> select lineage-*-UNOFFICIAL-<target>.zip
#   Then the same qcow2 boots Android afterwards.
#
# Note:
# This script uses qemu-nbd + partitioning tools (sgdisk/mkfs.vfat). Run on Linux host.
#
# Usage (outside container, from ANDROID TOP):
#   sudo device/maleicacid/androidtv-tools/image/make_selfcontained_qcow2.sh r86s_tv_virtio
#
# Options:
#   --size 32G          Total virtual size for qcow2 (default: 32G)
#   --install-mib 2048  Size of INSTALL partition (default: 2048 MiB)
#   --nbd /dev/nbd0     Which NBD device to use (default: /dev/nbd0)
#   --out <path>        Output qcow2 path (default: out/target/product/<p>/androidtv-<p>.qcow2)

PRODUCT="lineage_${1:-}"
shift || true

if [[ -z "${PRODUCT}" ]]; then
  echo "Usage: $0 <r86s_tv_virtio|qemu_tv_virtio> [--size 32G] [--install-mib 2048] [--nbd /dev/nbd0] [--out path]" >&2
  exit 1
fi

SIZE="32G"
INSTALL_MIB="2048"
NBD_DEV="/dev/nbd0"
OUT_PATH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --size) SIZE="$2"; shift 2;;
    --install-mib) INSTALL_MIB="$2"; shift 2;;
    --nbd) NBD_DEV="$2"; shift 2;;
    --out) OUT_PATH="$2"; shift 2;;
    *) echo "Unknown arg: $1" >&2; exit 1;;
  esac
done

TOP="$(cd "$(dirname "$0")/../.." && pwd)"
OUT_DIR="${TOP}/out/target/product/${PRODUCT}"

INSTALL_IMG="$(ls -1 "${OUT_DIR}"/lineage-*-UNOFFICIAL-"${PRODUCT}".img 2>/dev/null | head -n1 || true)"
FLASH_ZIP="$(ls -1 "${OUT_DIR}"/lineage-*-UNOFFICIAL-"${PRODUCT}".zip 2>/dev/null | head -n1 || true)"

if [[ -z "${INSTALL_IMG}" ]]; then
  echo "[!] espimage-install output not found: ${OUT_DIR}/lineage-*-UNOFFICIAL-${PRODUCT}.img" >&2
  echo "    Run: device/maleicacid/androidtv-tools/docker/build_in_docker.sh ${PRODUCT}" >&2
  exit 1
fi
if [[ -z "${FLASH_ZIP}" ]]; then
  echo "[!] flashable zip not found: ${OUT_DIR}/lineage-*-UNOFFICIAL-${PRODUCT}.zip" >&2
  echo "    Ensure otapackage/bacon was built." >&2
  exit 1
fi

if [[ -z "${OUT_PATH}" ]]; then
  OUT_PATH="${OUT_DIR}/androidtv-${PRODUCT}.qcow2"
fi

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
echo ""
echo "First boot (inside VM):"
echo "  1) It should boot into installer/recovery."
echo "  2) In Recovery:"
echo "       Factory reset -> Format data"
echo "       Apply update -> Choose INSTALL -> select the copied zip"
echo "  3) Reboot system now"
echo ""
echo "After install, the SAME qcow2 should boot Android."
echo "============================================================"
