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
echo '== DRM / HDCP / graphics errors in logcat =='
adb logcat -d -b all | grep -Ei 'hdcp|widevine|hwcomposer|mediadrm|CANNOT LINK|avc: denied' | tail -n 120 || true
echo 'NOTE: These diagnostics do not prove Widevine sessions, content decryption, or HDCP authentication.'
