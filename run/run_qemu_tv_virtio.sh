#!/usr/bin/env bash
set -euo pipefail

# Convenience runner for qemu_tv_virtio (no GPU passthrough).
# Usage:
#   device/maleicacid/androidtv-tools/run/run_qemu_tv_virtio.sh out/target/product/qemu_tv_virtio/androidtv-qemu_tv_virtio.qcow2

QCOW2="${1:-}"
if [[ -z "${QCOW2}" || ! -f "${QCOW2}" ]]; then
  echo "Usage: $0 <androidtv-qemu_tv_virtio.qcow2>" >&2
  exit 1
fi

OVMF_CODE="/usr/share/OVMF/OVMF_CODE_4M.fd"
OVMF_VARS="./OVMF_VARS_4M.fd"
if [[ ! -f "${OVMF_VARS}" ]]; then
  cp /usr/share/OVMF/OVMF_VARS_4M.fd "${OVMF_VARS}"
fi

exec qemu-system-x86_64 \
  -enable-kvm \
  -machine q35,accel=kvm \
  -cpu host \
  -smp 4 -m 4096 \
  -drive if=pflash,format=raw,readonly=on,file="${OVMF_CODE}" \
  -drive if=pflash,format=raw,file="${OVMF_VARS}" \
  -drive if=virtio,file="${QCOW2}",format=qcow2 \
  -device virtio-gpu-pci \
  -device ich9-intel-hda -device hda-output \
  -device usb-kbd -device usb-mouse \
  -netdev user,id=net0 \
  -device virtio-net-pci,netdev=net0
