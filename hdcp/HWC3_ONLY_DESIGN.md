# R86S Android 15: preserve existing HWC3, add no new HWC2 dependency (2026-11-16)

## Decision and exclusions

- **Required:** Widevine **L3** AIDL DRM HAL, genuine Widevine-encrypted playback with an HDCP-free test license, and (separately) HDMI HDCP when a protected-output license requires it.
- **Not required:** Widevine **L1**, trusted execution / secure video path or certification.
- **HWC policy:** preserve the existing LineageOS 22.1 AIDL HWC3 service and its existing HWC2-derived internal code **unchanged**. Adding Widevine L3 or HDCP must introduce **no additional HWC2 service, HWC2-to-HWC3 adapter or HWC2-specific integration dependency**. No requirement to remove the HWC2 code already required by upstream.
- Prefer the existing Android 15 HWC3 service and its DRM/KMS core. Reuse Celadon's connector-property logic as a design reference, without adopting its HWC2-only `libhwcservice` bridge. Any later HDCP controller must use the existing DRM/KMS owner and a verified Android 15 request path; do not create an independent connector-property writer.

## Exact source audit: what exists and what does not

| Path/component | Evidence | Implication |
|---|---|---|
| `LineageOS/android_device_virt_virtio_x86_64@lineage-22.1/device.mk` | Packages `android.hardware.composer.hwc3-service.drm.virtio_x86_64` | Product chooses HWC3 AIDL. |
| `.../configs/init/virtio_x86_64-graphics.rc` | `ro.vendor.graphics.gpu=i915` enables `vendor.hwcomposer-3.virtio_x86_64` | Retain the i915 property. |
| `.../hals/hwcomposer/drm/Android.bp` | Soong `filegroup` **`virtio_x86_64_drm_hwcomposer_common`** includes `hwc2_device/DrmHwcTwo.cpp`, `HwcDisplay.cpp`, `HwcLayer.cpp`, `hwc2_device.cpp`, plus DRM/KMS. The existing HWC3 `cc_binary` includes that filegroup and `:drm_hwcomposer_hwc3`. | **Existing upstream implementation: leave untouched.** No new HWC2 inputs may be introduced **by this feature**. The name HWC3 alone does not imply no HWC2-derived internal code. |
| `.../hals/hwcomposer/drm/drm` and `.../hwc2_device` | Symlinks to `external/drm_hwcomposer` | Source modifications must target the owning external module or an explicit, narrow override. Do not edit symlink placeholders. |
| Celadon `hdcp/daemon/Android.bp` at pinned SHA | `hdcpd` links `libhwcservice` | The daemon requires the bridge, not a second hardware composer. |
| Celadon `hdcp/daemon/portmanager_android.cpp` | `HwcService_Connect` and `HwcService_Video_EnableHDCPSession_ForDisplay` | The daemon-to-HWC link is real; direct ELF dependencies of Widevine are irrelevant to this separate output-protection path. |
| Celadon `drm-hwcomposer/drm/ResourceManager.cpp` | Starts a `HwcService` using its HWC2 frontend; `DrmHwcTwo.cpp` calls `DrmAtomicStateManager::SetHDCPState` | **Not a drop-in HWC3-native bridge.** Port connector-state logic, rather than installing Celadon's legacy HWC2 interface. |
| Celadon `drm-hwcomposer/hwc3-server/default/impl/HwcLoader.cpp` | Loads a `hwc2_device_t` | Do **not introduce this adapter** as part of the new HDCP integration. It is unrelated to the upstream LineageOS implementation retained above. |
| Android 15 `IComposerCallback.aidl` | Defines `onHdcpLevelsChanged` | A callback conveys state, not a negotiation command. |
| Android 15 `IComposerClient.aidl` | No `startHdcpNegotiation` | Do not silently import a later HAL contract. Identify the Android 15 DRM-policy/request source before implementation. |

## Minimal integration design: no additional HWC2 dependency

1. **Preserve upstream unchanged.** LineageOS 22.1's manifest resolves `external/drm_hwcomposer` from AOSP tag `android-15.0.0_r14`. Its `hwc3/ComposerClient.cpp` directly includes `hwc2_device/HwcDisplay.h` and calls its display/layer methods. These are existing dependencies, intentionally outside this feature's scope. Do not start an HWC2 cleanup/refactor.
2. **Select the HDMI/DP state owner.** Keep one current HWC3/DRM master. Introduce no new HWC2 frontend, `hwc.info` bridge, HWC2 HAL or second compositor. A KMS HDCP controller must be integrated into the existing owner's connector state and follow its synchronization/atomic commit strategy.
3. **Define the protection controller contract.** If an authorized request source is established, the current DRM/KMS owner tracks connector ID, available `Content Protection`/`HDCP Content Type`, requested level, readback and link loss. A write to `Desired` is not equivalent to successful `Enabled` authentication. Preserve the currently running HWC3 and its upstream internal HWC2-derived implementation.
4. **Establish an authorized Android 15 request source before writing code.** `IComposerCallback.onHdcpLevelsChanged` is a notification; Android 15 lacks the later `startHdcpNegotiation` request. A secure-layer indicator alone does not establish a license-required HDCP version. Do not infer a request or license policy from static ELF strings; verify Widevine HAL behavior and an actual DRM-to-display path. If no valid request source is demonstrated, mark license-driven HDMI HDCP **BLOCKED**, and do not add a fake IPC or issue unconditional HDCP requests.
5. Follow fail-closed behavior on unsupported connector, hotplug, reauthentication failure, insufficient HDCP level, or lost link. Add unit/system tests against a mocked DRM/KMS connector; real Intel GPU/MEI, sink and HDCP behavior require hardware evidence.
6. Keep Widevine L3 independent of HDCP: `IDrmFactory/widevine` registration, openSession/provisioning, a real HDCP-free Widevine license, and decrypted frames. **Never claim L1**.

## Repository responsibility and integration sequence

1. `virtio_x86_64_tv_grub` owns R86S product packages/properties and vendor policy. Pin its HEAD via `hdcp/93-hdcp.xml` (with `upstream` for `repo sync -c`).
2. `android_device_maleicacid_androidtv_tools` owns R86S-only local manifests, static contract CI and pinned source revisions. `vendor/google/proprietary/widevine-prebuilt` is pinned to the same SHA the ELF audit scans.
3. Native HWC3 modifications belong in a separately reviewable patch/branch in **the actual `external/drm_hwcomposer` owner**. Do not copy entire Celadon HWC tree or make the build script rewrite third-party sources after sync.
4. Static contract CI checks **presence of desired configuration** and **reported unresolved dependencies**, not functional HDCP. Full Android 15 Soong, VINTF, sepolicy, VTS and real device acceptance remain independent gates.

## Acceptance matrix

| Check | Status after these PR edits | Proof required |
|---|---|---|
| Source/ABI contract recorded | Audit + static checks | CI logs, manifests, build definitions |
| Existing HWC2 internals retained; no additional HWC2 integration | **Design accepted; unchanged upstream** | PR/config diff must contain no new HWC2 service, adapter or bridge |
| HWC3-owned HDCP controller | **Not done** | Source, unit tests and real KMS state |
| Widevine L3 | **Not proven** | MediaDrm L3 session, genuine encrypted video playback |
| HDMI HDCP | **Not proven** | PCI passthrough, i915/MEI, connector negotiation and license-based playback |
| Widevine L1 | Out of scope | No L1 acceptance claim |

## Source references

- [LineageOS 22.1 HWC3 module definition](https://github.com/LineageOS/android_device_virt_virtio_x86_64/blob/lineage-22.1/hals/hwcomposer/drm/Android.bp)
- [LineageOS graphics init](https://github.com/LineageOS/android_device_virt_virtio_x86_64/blob/lineage-22.1/configs/init/virtio_x86_64-graphics.rc)
- [Celadon daemon dependency](https://github.com/projectceladon/hdcp/blob/ccd30e43b3205e22aff9d2aa09a11aa0d4f3870d/daemon/Android.bp)
- [Celadon bridge call](https://github.com/projectceladon/hdcp/blob/ccd30e43b3205e22aff9d2aa09a11aa0d4f3870d/daemon/portmanager_android.cpp)
- [Celadon HWC2 bridge](https://github.com/projectceladon/drm-hwcomposer/blob/main/hwc2_device/hwcservice.cpp)
- [Celadon HWC3 loader](https://github.com/projectceladon/drm-hwcomposer/blob/main/hwc3-server/default/impl/HwcLoader.cpp)
- [Android 15 Composer AIDL](https://github.com/LineageOS/android_hardware_interfaces/blob/lineage-22.1/graphics/composer/aidl/android/hardware/graphics/composer3/IComposerClient.aidl)
