#!/usr/bin/env bash
# Read-only host-side R86S PCI / IOMMU / i915 / MEI feasibility evidence.
# Run on the Linux host. This script does not bind devices or change drivers.
set -euo pipefail

echo "== Host kernel =="
uname -a
echo "== PCI devices and bound kernel drivers =="
if command -v lspci >/dev/null 2>&1; then
  lspci -nnk
else
  echo "lspci unavailable (install pciutils)"
fi

echo "== IOMMU grouping (sysfs; no modification) =="
if [[ -d /sys/kernel/iommu_groups ]]; then
  found=0
  while IFS= read -r -d '' node; do
    found=1
    printf '%s => %s\n' "$node" "$(readlink -f "$node")"
  done < <(find /sys/kernel/iommu_groups -type l -print0 | sort -z)
  if [[ "$found" == 0 ]]; then
    echo "No IOMMU groups exposed"
  fi
else
  echo "No /sys/kernel/iommu_groups directory"
fi

echo "== Graphics and HDCP-related modules =="
if command -v lsmod >/dev/null 2>&1; then
  lsmod | grep -Ei '^(i915|xe|mei|drm)' || true
else
  echo "lsmod unavailable"
fi

echo "== Host DRM connectors and status =="
shopt -s nullglob
for connector in /sys/class/drm/card*-*/status; do
  printf '%s: ' "$connector"
  if [[ -r "$connector" ]]; then cat "$connector"; else echo "unreadable"; fi
done
echo "== Host DRM kernel messages (may be inaccessible without permissions) =="
if command -v journalctl >/dev/null 2>&1; then
  journalctl -k --no-pager -n 200 2>/dev/null | grep -Ei 'drm|i915|mei|hdcp|iommu|vfio' | tail -100 || true
else
  echo "journalctl unavailable"
fi
echo "NOTE: This is host-side feasibility evidence, NOT guest PCI passthrough,"
echo "      KMS Content Protection support, HDCP authentication or Widevine L3."
