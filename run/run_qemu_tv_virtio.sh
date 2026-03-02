#!/usr/bin/env bash
set -euo pipefail

QCOW2="${1:-}"
if [[ -z "${QCOW2}" ]]; then
  echo "Usage: $0 <qcow2>" >&2
  exit 1
fi

qemu-system-x86_64   -enable-kvm   -machine q35   -cpu host   -smp 4 -m 4096   -drive if=virtio,file="${QCOW2}",format=qcow2   -device virtio-gpu-pci   -device ich9-intel-hda -device hda-output   -netdev user,id=net0   -device virtio-net-pci,netdev=net0
