#!/usr/bin/env bash
# Read-only A15 DRM/HWC diagnostics; no HDCP enablement or vendor-policy changes.
set -euo pipefail
command -v adb >/dev/null || { echo "adb is required" >&2; exit 2; }
adb wait-for-device
echo '== Hardware composer / graphics properties =='
adb shell getprop ro.vendor.graphics.gpu
adb shell getprop ro.hardware.hwcomposer
adb shell getprop init.svc.vendor.hwcomposer-3
echo '== DRM and composer services =='
adb shell service list | grep -Ei 'drm|composer' || true
echo '== DRM HAL state =='
adb shell dumpsys media.drm || true
echo '== DRM connectors and kernel HDCP sysfs (if exposed) =='
adb shell 'ls -l /sys/class/drm 2>/dev/null; for f in /sys/class/drm/*/status; do [ -r "$f" ] && { echo "$f"; cat "$f"; }; done' || true
echo '== Sample real connector Content Protection via modetest, if available =='
# Reading DRM properties is independent of composing or setting Desired.
# Require a real DRM/KMS tool in guest; never interpret sysfs status as HDCP.
if adb shell 'command -v modetest >/dev/null 2>&1'; then
  for i in 1 2 3 4 5; do
    echo "== KMS sample $i (UTC $(date -u +%Y-%m-%dT%H:%M:%SZ)) =="
    adb shell 'modetest -M i915 -c -p 2>&1' || true
    if [[ "$i" -lt 5 ]]; then sleep 2; fi
  done
else
  echo 'NOT VERIFIED: modetest unavailable in Android guest; use a matching read-only libdrm test binary with access to /dev/dri/card*'
fi
echo 'ACCEPTANCE: capture Undesired -> Desired -> Enabled via actual Content Protection property.'
echo 'REAUTH: disconnect/reconnect sink and capture Enabled -> Desired -> Enabled, if supported.'
echo 'FAIL: no Enabled; a successful atomic ioctl alone is not HDCP.'
echo 'Do not infer HDCP 2.2 solely from HDCP Content Type (or a successful commit).'
echo '== DRM / HDCP / graphics errors in logcat =='
adb logcat -d -b all | grep -Ei 'hdcp|widevine|hwcomposer|mediadrm|CANNOT LINK|avc: denied' | tail -n 120 || true
echo 'NOTE: These diagnostics do not prove Widevine sessions, content decryption, or HDCP authentication.'
