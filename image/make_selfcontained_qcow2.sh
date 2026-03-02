#!/usr/bin/env bash
set -euo pipefail

PRODUCT="${1:-}"
if [[ -z "${PRODUCT}" ]]; then
  echo "Usage: $0 <r86s_tv_virtio|qemu_tv_virtio>" >&2
  exit 1
fi

OUT_DIR="out/target/product/${PRODUCT}"
IMG=$(ls ${OUT_DIR}/lineage-*-UNOFFICIAL-${PRODUCT}.img | head -n1)
ZIP=$(ls ${OUT_DIR}/lineage-*-UNOFFICIAL-${PRODUCT}.zip | head -n1)

OUT="${OUT_DIR}/androidtv-${PRODUCT}.qcow2"

qemu-img convert -f raw -O qcow2 "$IMG" "$OUT"
qemu-img resize "$OUT" 32G

echo "qcow2 created: $OUT"
echo "Boot once, install zip from recovery, reboot."
