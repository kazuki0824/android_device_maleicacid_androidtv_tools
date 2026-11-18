#!/usr/bin/env bash
# Read-only effective kernel-config check for the Android guest or Linux host.
# Usage: bash hdcp/check_kernel_hdcp_config.sh guest|host [/path/to/.config]
set -euo pipefail
role="guest"
if (( $# > 0 )); then role="$1"; fi
case "$role" in guest|host) ;; *) echo "Usage: $0 guest|host [kernel .config]" >&2; exit 2 ;; esac
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp)"
trap 'rm -f -- "$tmp"' EXIT
if (( $# > 1 )); then
  if [[ "$2" == *.gz ]]; then gzip -cd "$2" > "$tmp"; else cat "$2" > "$tmp"; fi
elif [[ -r /proc/config.gz ]]; then
  gzip -cd /proc/config.gz > "$tmp"
elif [[ -r "/boot/config-$(uname -r)" ]]; then
  cat "/boot/config-$(uname -r)" > "$tmp"
elif [[ -r "/lib/modules/$(uname -r)/build/.config" ]]; then
  cat "/lib/modules/$(uname -r)/build/.config" > "$tmp"
else
  echo "UNVERIFIED: effective running kernel .config unavailable." >&2
  echo "Provide .config as second argument; source fragments cannot substitute." >&2
  exit 2
fi
if [[ "$role" == guest ]]; then
  python3 "$here/audit_kernel_hdcp.py" effective --role guest --hdcp22 --config "$tmp"
  echo "== Guest GPU and MEI (read-only) =="
  if command -v lspci >/dev/null 2>&1; then lspci -nnk | grep -Ei -A5 'VGA|Display|Management Engine' || true; fi
  if command -v lsmod >/dev/null 2>&1; then lsmod | grep -Ei '^(i915|mei|mei_me|mei_hdcp)' || true; fi
  ls -ld /dev/dri/* /dev/mei* 2>/dev/null || true
  echo "NOT PROVEN: hardware MEI is passed to guest or HDCP authenticates."
else
  python3 "$here/audit_kernel_hdcp.py" effective --role host --config "$tmp"
  echo "NOT PROVEN: IOMMU grouping, VFIO binding or MEI passthrough."
fi
