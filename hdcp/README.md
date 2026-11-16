# Temporary R86S Widevine L3 / HDMI HDCP verification (PR #22)

**Temporary Draft PR; do not merge.** This is a read-only/diagnostic companion to the
[product tools PR #15](https://github.com/kazuki0824/android_device_maleicacid_androidtv_tools/pull/15)
and [R86S device PR #10](https://github.com/kazuki0824/virtio_x86_64_tv_grub/pull/10).
PR #15 targets main; PR #22 is stacked immediately above #15.

## Actual product vs temporary verification

- **Product tools #15:** includes the narrow
  `patches/lineage-22.1/drm_hwcomposer_i915_hdcp_desired.patch`
  and registration in `apply_patches.sh`. It attempts a one-shot, best-effort
  DRM/KMS `Content Protection=Desired` for R86S/i915 HDMI-A after a
  successful composition. It has **not** proved `Enabled`, reconnect recovery,
  HDCP version, or DRM license enforcement.
- **Product device #10:** R86S i915 property and Widevine vendor SELinux labels.
  Existing LineageOS HWC3 and pre-existing HWC2-derived internals remain.
  No new HWC2 service, bridge, or second DRM master.
- **Temporary #22:** local HDCP source overlay, source and ELF audit scripts,
  GitHub Actions, and diagnostics/build-test driver. Nothing in this PR is
  required to remain in the merged product.

## Moving product source vs fixed audit snapshot

The product's `virtio_x86_64_tv_grub.xml` intentionally specifies
`revision="celadon"` for
`supremegamers/vendor_google_proprietary_widevine-prebuilt`.
The **test-only ELF investigations** fetch
`47992c25673ed766155fc52d0e6ae81d9769a06c` so the binary evidence is
repeatable. This audit SHA is **not a product revision pin**. If celadon
changes, static findings must be rechecked against the actual build checkout.

For experimental R86S source acquisition, `get_android_qcow2.sh` copies
`hdcp/93-hdcp.xml` to `.repo/local_manifests/zz-hdcp.xml`. This pins
device PR #10's current SHA and checks out Celadon HDCP code **for inspection**,
not for installation as a working HDCP daemon. Normal QEMU TV does not take
this overlay.

## Host-side data collection (no PCI/driver changes)

On the **R86S Linux host**, run `bash hdcp/check_r86s_host_hdcp.sh`.
This read-only report covers `uname -a`, `lspci -nnk`, sysfs IOMMU
groups, relevant kernel modules, and connector status. It never binds or
unloads a device. Distinguish host support from the Android guest's actual
access to i915/MEI and its physical HDMI connector. No result has been
collected from the R86S yet.

## R86S product kernel fragment (device #10)

The product's [device PR #10](https://github.com/kazuki0824/virtio_x86_64_tv_grub/pull/10)
now adds `r86s_virtio_tv/configs/kernel/hdcp.config` with
`CONFIG_INTEL_MEI=m`, `CONFIG_INTEL_MEI_ME=m` and
`CONFIG_INTEL_MEI_HDCP=m`, connected through the product-specific
`TARGET_KERNEL_CONFIG` in `r86s_virtio_tv/BoardConfig.mk`. That product
also lists `mei.ko`, `mei-me.ko`, `mei_hdcp.ko`, and `i915.ko` in
`BOARD_VENDOR_KERNEL_MODULES_LOAD`, so LineageOS can generate vendor_dlkm's
`modules.load` from the built modules.
This uses the established product-owned Kconfig fragment mechanism.
Temporary CI verifies the source wiring and pin to device SHA
`2b152fd5242075b9ca7730b2256eb7eb5aff1554`. Source wiring alone does not prove that a prebuilt kernel
uses the fragment or that these modules are packaged and loadable.
Inspect the effective kernel `.config` and module inventory before
asserting HDCP 2.x support.

## Intel i915 / MEI / HDCP kernel prerequisites

[Kernel prerequisite workflow](https://github.com/kazuki0824/android_device_maleicacid_androidtv_tools/actions/workflows/r86s-kernel-hdcp-audit.yml)
verifies the LineageOS 22.1 *source* contract, including Kconfig dependencies and
the GPU-passthrough fragment. It **cannot** certify that the guest boots that
kernel or contains the corresponding modules. A prebuilt Linux 6.6 kernel
may be selected instead of compiling the inspected source tree.

- Source `gki_defconfig`: `CONFIG_DRM=y`.
- Source GPU passthrough fragment: `CONFIG_DRM_I915=m`.
- `CONFIG_INTEL_MEI`, `CONFIG_INTEL_MEI_ME` and
  `CONFIG_INTEL_MEI_HDCP`: **not specified in the inspected fragments**.
  That is **not** a conclusion that the effective configuration disables them.
- The Linux 6.6 i915 HDCP 2.x path references
  `IS_ENABLED(CONFIG_INTEL_MEI_HDCP)`. The MEI-backed hardware path
  depends on firmware/device access beyond the Kconfig values.
- `CONFIG_INTEL_MEI_HDCP` is pertinent to **MEI-backed HDCP 2.x**;
  its absence alone does not establish that HDCP 1.4 is impossible.
- `CONFIG_DRM_I915=m` means the driver may be a module. A Kconfig
  value is not evidence that `i915.ko`, `mei.ko`, `mei_me.ko`,
  and `mei_hdcp.ko` are installed, loaded and bound to the guest hardware.

On an **Android guest** with the **actual effective kernel config**, run:

```bash
bash hdcp/check_kernel_hdcp_config.sh guest /path/to/actual/.config
```

The script also attempts to read `/proc/config.gz` or `/boot/config-$(uname -r)`
when available. Use the actual booted or packaged kernel config, **not**
a sparse kernel-source fragment. This is a read-only check.
On the **Linux host**, use `bash hdcp/check_r86s_host_hdcp.sh` for
PCI/IOMMU/driver binding and separately inspect its own config with
`bash hdcp/check_kernel_hdcp_config.sh host /path/to/host/.config`.

If the guest lacks required MEI-HDCP support, the product kernel
configuration/modules must be addressed in the **production owner**,
not committed as a build workaround into temporary PR #22.
The i915/HDCP patch in tools #15 does not compensate for missing
kernel features or inaccessible host MEI firmware.

## Evidence categories

| Proof | Status |
|---|---|
| Historical Widevine ELF dependencies, HDCP symbols/call edges | Static evidence exists; no runtime guarantee |
| Actual product `celadon` branch manifest and source sync | Test in `widevine-elf-audit.yml` |
| Production HWC3 HDCP patch on AOSP Android 15 source | Test via `hdcp-hwc3-patch-apply.yml` (`git apply --check` and application) |
| Soong HWC3 + Widevine, vendor SELinux, VINTF | **Not run**; use `hdcp/verify_android15_r86s_build.sh` in a prepared A15 tree |
| Widevine L3 HDCP-free licensed encrypted playback | **Not run** |
| Real R86S physical HDMI `Desired → Enabled`, loss/reconnect | **Not run** |
| HDCP-required Widevine L3 license enforcement | **Not run** |

A test APK must actually acquire a Widevine license and decrypt encrypted
video; ClearKey or unencrypted MP4 does not prove Widevine L3.
Read-only Android diagnostics: `hdcp/check_android_drm.sh`.
Host/guest i915, MEI, IOMMU, physical HDMI sink and KMS properties must be
measured, not inferred from ELF or CI success.

**Completion:** bring any product-required fixes to #15 or device #10 separately;
then close #22 **unmerged**. Do not mistake successful syntax/patch/ELF CI for
an Android 15 build, HDCP authentication, or secure output-policy enforcement.
