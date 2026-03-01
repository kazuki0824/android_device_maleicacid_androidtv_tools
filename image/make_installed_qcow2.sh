#!/usr/bin/env bash
set -euo pipefail

PRODUCT="${1:-}"
if [[ -z "${PRODUCT}" ]]; then
  echo "Usage: $0 <r86s_tv_virtio|qemu_tv_virtio> [disk_size_gib]" >&2
  exit 1
fi

SIZE="${2:-16}"

TOP="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${TOP}/out/target/product/${PRODUCT}"

INSTALL_IMG="$(ls -1 "${OUT}"/lineage-*-UNOFFICIAL-"${PRODUCT}".img 2>/dev/null | head -n1 || true)"
OTA_ZIP="$(ls -1 "${OUT}"/lineage-*-UNOFFICIAL-"${PRODUCT}".zip 2>/dev/null | head -n1 || true)"

if [[ -z "${INSTALL_IMG}" ]]; then
  echo "[!] installer .img not found. Did you run: m espimage-install ?" >&2
  exit 1
fi
if [[ -z "${OTA_ZIP}" ]]; then
  echo "[!] OTA zip not found. Did you run: m otapackage ?" >&2
  exit 1
fi

DISK="${OUT}/androidtv-${PRODUCT}.qcow2"
OVMF_CODE="/usr/share/OVMF/OVMF_CODE_4M.fd"
OVMF_VARS="${OUT}/OVMF_VARS.fd"

if [[ ! -f "${OVMF_VARS}" ]]; then
  cp /usr/share/OVMF/OVMF_VARS_4M.fd "${OVMF_VARS}"
fi

if [[ ! -f "${DISK}" ]]; then
  qemu-img create -f qcow2 "${DISK}" "${SIZE}G"
fi

qemu-system-x86_64 \
  -enable-kvm \
  -machine q35,accel=kvm \
  -cpu host \
  -smp 4 -m 4096 \
  -drive if=pflash,format=raw,readonly=on,file="${OVMF_CODE}" \
  -drive if=pflash,format=raw,file="${OVMF_VARS}" \
  -drive if=virtio,file="${DISK}",format=qcow2 \
  -drive if=none,file="${INSTALL_IMG}",format=raw,id=inst \
  -device qemu-xhci \
  -device usb-storage,drive=inst,removable=on \
  -virtfs local,path="$(dirname "${OTA_ZIP}")",mount_tag=host,security_model=none,readonly=on \
  -device virtio-gpu-pci \
  -device ich9-intel-hda -device hda-output \
  -device usb-kbd -device usb-mouse \
  -netdev user,id=net0 \
  -device virtio-net-pci,netdev=net0
