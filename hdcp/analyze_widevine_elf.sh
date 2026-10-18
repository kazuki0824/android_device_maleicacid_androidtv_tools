#!/usr/bin/env bash
set -euo pipefail

# Read-only ELF inspection of public Widevine prebuilts. Never execute them.
rev="47992c25673ed766155fc52d0e6ae81d9769a06c"
base="https://raw.githubusercontent.com/supremegamers/vendor_google_proprietary_widevine-prebuilt/${rev}"
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
cd "$workdir"

for binary in android.hardware.drm-service.widevine libwvaidl.so; do
  echo "::group::${binary}"
  curl --fail --show-error --location --retry 3 --retry-all-errors --max-time 90 \
    --output "$binary" "${base}/${binary}"
  echo "--- sha256 / ELF class / interpreter ---"
  sha256sum "$binary"
  file "$binary"
  readelf -hW "$binary" | grep -E 'Class:|Machine:|Type:'
  readelf -lW "$binary" | grep -E 'INTERP|Requesting program interpreter' || true
  echo "--- DT_NEEDED, RPATH, RUNPATH, SONAME ---"
  readelf -dW "$binary" | grep -E '\((NEEDED|RPATH|RUNPATH|SONAME)\)' || true
  echo "--- Dynamic ELF imports related to runtime linking / HDCP ---"
  readelf --dyn-syms -W "$binary" | grep -Ei ' UND .*\b(dlopen|dlsym|android_dlopen_ext|hdcp[^ ]*|HwcService[^ ]*)' | head -50 || true
  echo "--- HDCP / output-protection strings (capped, no raw dump) ---"
  strings -a "$binary" |
    grep -Ei 'hdcp|hwc\.info|\.sdk_socket|/data/vendor/hdcp|libhdcp' |
    head -80 || true
  echo "--- IPC and dynamic symbol imports ---"
  readelf --dyn-syms -W "$binary" |
    grep -Ei ' UND .*(dlopen|dlsym|android_dlopen_ext|socket|connect|AServiceManager_|AIBinder_|ioctl)' |
    head -60 || true
  echo "--- Exact daemon/library/socket references (ASCII and UTF-16LE) ---"
  for token in 'libhdcpsdk' 'libhwcservice' 'hdcpd' 'hwc.info' '.sdk_socket' '/data/vendor/hdcp'; do
    ascii='absent'
    utf16='absent'
    if LC_ALL=C grep -aFq "$token" "$binary"; then ascii='present'; fi
    if strings -el "$binary" | grep -Fq "$token"; then utf16='present'; fi
    printf '%s: ascii=%s utf16le=%s\\n' "$token" "$ascii" "$utf16"
  done
  echo "--- Candidate dynamically loaded library paths (deduplicated) ---"
  strings -a "$binary" |
    grep -Eio '[A-Za-z0-9_./+-]*lib[A-Za-z0-9_.+-]+\\.so([.0-9]+)?' |
    sort -u | head -80 || true
  echo "::endgroup::"
done
