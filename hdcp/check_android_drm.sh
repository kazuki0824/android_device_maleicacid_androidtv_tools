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
echo '== SELinux service domain and installed labels (read-only) =='
adb shell 'ls -lZ /vendor/bin/hw/android.hardware.drm-service.widevine /data/vendor/mediadrm 2>&1; ps -AZ | grep -Ei "widevine|drm" || true' || true
echo '== DRM HAL state =='
adb shell dumpsys media.drm || true
echo '== DRM connectors and kernel HDCP sysfs (if exposed) =='
adb shell 'ls -l /sys/class/drm 2>/dev/null; for f in /sys/class/drm/*/status; do [ -r "$f" ] && { echo "$f"; cat "$f"; }; done' || true
echo '== Sample real connector Content Protection via modetest, if available =='
# Reading DRM properties is independent of composing or setting Desired.
# Require a real DRM/KMS tool in guest; never interpret sysfs status as HDCP.
evidence_file="${HDCP_KMS_LOG:-${PWD}/r86s-hdcp-kms-samples.log}"
: > "$evidence_file"
kms_rc=0
if adb shell 'command -v modetest >/dev/null 2>&1'; then
  samples="${HDCP_KMS_SAMPLES:-5}"
  interval="${HDCP_KMS_INTERVAL_SECONDS:-2}"
  for ((i=1; i<=samples; i++)); do
    printf '== KMS sample %d (UTC %s) ==\\n' "$i" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" | tee -a "$evidence_file"
    rc=0
    output="$(adb shell 'modetest -M i915 -c -p 2>&1' 2>&1)" || rc=$?
    printf '%s\\n' "$output" | tee -a "$evidence_file"
    printf 'modetest_exit=%d\\n' "$rc" | tee -a "$evidence_file"
    if (( rc != 0 )); then
      printf 'UNVERIFIED: modetest failed with exit %d on sample %d\\n' "$rc" "$i"
      kms_rc=2
    fi
    if (( i < samples )); then sleep "$interval"; fi
  done
else
  echo 'UNVERIFIED: modetest unavailable in guest; use read-only libdrm with /dev/dri/card* access'
  printf 'modetest unavailable\\n' >> "$evidence_file"
  kms_rc=2
fi
if [[ -f "$(dirname "$0")/classify_kms_hdcp.py" ]]; then
  python3 "$(dirname "$0")/classify_kms_hdcp.py" "$evidence_file" || kms_rc=2
else
  echo 'UNVERIFIED: classification code is unavailable'
  kms_rc=2
fi
echo "KMS evidence file: $evidence_file"
echo 'ACCEPTANCE: capture Undesired -> Desired -> Enabled via actual Content Protection property.'
echo 'REAUTH: disconnect/reconnect sink and capture Enabled -> Desired -> Enabled, if supported.'
echo 'FAIL: no Enabled; a successful atomic ioctl alone is not HDCP.'
echo 'Do not infer HDCP 2.2 solely from HDCP Content Type (or a successful commit).'
echo '== DRM / HDCP / graphics errors in logcat =='
adb logcat -d -b all | grep -Ei 'hdcp|widevine|hwcomposer|mediadrm|CANNOT LINK|avc: denied' | tail -n 120 || true
echo 'NOTE: These diagnostics do not prove Widevine sessions, content decryption, or HDCP authentication.'
exit "$kms_rc"
