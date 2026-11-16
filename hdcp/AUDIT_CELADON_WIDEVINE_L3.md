# R86S Widevine L3 + HDCP: completed source/PR diff audit (2026-11-16)

## Scope and evidence standard

Scope: tools PR [#15](https://github.com/kazuki0824/android_device_maleicacid_androidtv_tools/pull/15) at `547ce5ddc628184e4f29cb85ddd18418404c906c` (six changed files, +282/-0) and device PR [#10](https://github.com/kazuki0824/virtio_x86_64_tv_grub/pull/10) at `c2f82618b17e34cb7fbe1e3ead5b15a6c8b4f812` (five changed files, +23/-1). Audit covers **every changed file**, fixed HDCP source `projectceladon/hdcp@ccd30e43b3205e22aff9d2aa09a11aa0d4f3870d`, Celadon DRM HWC, LineageOS 22.1 graphics init and HWC3 module, and the actual selected Widevine prebuilt.

**Requirement:** Widevine **L3** with real Widevine-encrypted playback plus physical-link HDCP on the R86S Intel GPU passed to Android. **L1 is out of scope.** L3 and HDCP are independently validated; neither proves the other. This is a **source/design audit**, not a declaration of Android 15 build success or functional protected playback.

### A. Celadon implementation trace (verified from public source)

1. `projectceladon/hdcp/README.md` documents `HDCPCreate → HDCPEnumerateDisplay → HDCPSetProtectionLevel → HDCPGetStatus`; kernel DRM and suitable MEI/firmware are necessary for 2.2. Supported hardware depends on platform.
2. At the pinned SHA, `hdcp/daemon/Android.bp` compiles `hdcpd` with `-DUSES_HDCP_HWCOMPOSER` and **links `libhwcservice`**; `hdcp/sdk/Android.bp` provides `libhdcpsdk`.
3. `hdcp/daemon/portmanager_android.cpp` calls `HwcService_Connect` and `HwcService_Video_EnableHDCPSession_ForDisplay`. The Celadon `drm-hwcomposer/libhwcservice` implementation is the **client bridge**, not a second DRM master. Celadon `drm-hwcomposer/drm/ResourceManager.cpp` starts `HwcService` using its existing `DrmHwcTwo`.
4. `drm-hwcomposer/hwc2_device/DrmHwcTwo.cpp` forwards to `DrmAtomicStateManager::SetHDCPState`, which uses the active connector's DRM properties. **Important defect in the reference**: `HwcService::Controls::EnableHDCPSessionForDisplay` returns `OK` unconditionally after invoking a `void` method; it does *not* demonstrate KMS transition to `Enabled`. SRM handler methods contain TODOs returning OK. Preserve actual KMS-state/error verification when adapting.
5. Celadon's `hwc3-server` uses an HWC2 device loader/adapter, so the existence of an HWC3 service does not by itself mean the HWC2 bridge cannot work. Conversely this is **not** proof that the current LineageOS 22.1 HWC3 module exposes `hwc.info`.
6. Celadon's `device-androidia/caas/device.mk` enables `hdcpd`; its `caas/init.rc` starts it after `vendor.hwc.ready=1`. These are product/init responsibilities, not accomplished by merely fetching the `hdcp` repo. Their exact branch/build combination differs from R86S; use as a reference, **not** a drop-in.
7. LineageOS 22.1 `device/virt/virtio_x86_64/device.mk` installs `android.hardware.composer.hwc3-service.drm.virtio_x86_64`. `configs/init/virtio_x86_64-graphics.rc` selects the i915 route only if `ro.vendor.graphics.gpu=i915`. Its HWC3 `Android.bp` does not include the Celadon `libhwcservice` bridge. The `drm/` and `hwc2_device/` directories under the Lineage device are symlinks to **`external/drm_hwcomposer`**, not the Celadon fork.
8. Android 15's `IComposerCallback.aidl` has `onHdcpLevelsChanged` (notification), while the Android 15 `IComposerClient.aidl` does not provide `startHdcpNegotiation`. Neither notification nor the ELF scanner supplies an HDCP **request source**. A working design must identify which component requests a level for a protected-content license.

**Architecture decision after audit:** Retain one active HWC/DRM master. Do **not** reject `hdcpd` simply because it exists. Evaluate (A) porting the Celadon HWC service/HDCP code into the **existing** Android 15 compositor plus its client/daemon, versus (B) an equivalent single-owner KMS implementation with a proven DRM-policy request path. A compatibility failure or test result must justify excluding the Celadon route. Do not run two composers or let an unrelated process concurrently write the same connector state.

### B. Widevine L3 source and policy trace

- `virtio_x86_64_tv_grub.xml` fetches `supremegamers/vendor_google_proprietary_widevine-prebuilt` from a **floating `celadon` branch**, while the ELF script scans a **fixed** SHA `47992c25673ed766155fc52d0e6ae81d9769a06c`. This is a reproducibility hole: the audited binaries are not guaranteed to be the ones installed in a later build. **Fix before claiming tested behavior:** pin actual product prebuilt to a reviewed SHA and verify installed hashes.
- `lineage_x86_64_tv_common.mk` conditionally inherits `widevine.mk`. With the manifest present, that installs `android.hardware.drm-service.widevine` and `move_widevine_data`. Prebuilt `Android.bp` declares its own `init_rc`, `vintf_fragments`, and required `libwvaidl`; `check_elf_files: false` means ELF link completeness is not certified by Soong.
- The supplied init rc declares the AIDL factory `android.hardware.drm::IDrmFactory/widevine`; VINTF declares AIDL v1 `IDrmFactory/widevine`. These declarations must be checked by an **actual Android 15 build and running binder service**, not merely parsed as XML.
- The prebuilt's policy contains GPU, Composer, binder/allocator, tmpfs, and `hdcpd` communication permissions that the device PR omits. **Do not automatically copy broad rules or automatically declare all omitted rules safe.** Resolve each omission by the vendor sepolicy build, neverallow checks, AVC logs and L3/HDCP runtime calls. L1-only rights are not requested.
- `liboemcrypto.so` string presence and `dlopen`/ `dlsym` imports do not prove L1 necessity; the official Celadon *older-version* L3 guide documents an L3 fallback when the OEMCrypto library cannot be loaded. The behavior of these Android 15 prebuilts is **unverified**. L1 is explicitly excluded.
- Distinguish HDCP-free Widevine L3 encrypted-media acceptance from HDCP-required protected-output acceptance. A clear MP4, ClearKey, service registration alone, and an HDMI image each fail to prove the combined objective.
- The prebuilt's `move_widevine_data.sh` is installed as `move_widevine_data`; no invocation from its own rc is present. Treat any actual migration requirement as unverified; don't claim service-side migration automatically runs.

### C. Exhaustive changed-file disposition (PR #15)

| Changed file | Decision | Evidence / exact required follow-up |
|---|---|---|
| `get_android_qcow2.sh` | **KEEP, conditional** | R86S-only overlay copied as `zz-hdcp.xml`; other product removes the overlay. `repo sync ... || true` is pre-existing policy, not a new HDCP safety proof. Fail-fast is a separate issue. |
| `hdcp/93-hdcp.xml` | **KEEP + later UPDATE** | Explicit Celadon SHA and device SHA, resolved by existing CI. Any device PR commit must update the pinned `revision` atomically; the branch `upstream` remains usable for `repo sync -c`. Future HWC bridge requires its own explicitly pinned source. |
| `hdcp/analyze_widevine_elf.sh` | **KEEP with qualification** | Correctly establishes direct ELF imports/strings for a fixed prebuilt only; cannot exclude `dlopen`, IPC, output-protection policy, or actual playback dependencies. Align manifest prebuilt SHA to scanned SHA. |
| `hdcp/check_android_drm.sh` | **KEEP + later EXTEND** | Read-only diagnostics; does not prove L3 session, decrypted frames, HDCP version, or KMS Enabled. Add device-specific connector, `i915`/MEI, DRM HAL and MediaDrm assertions when runtime is available. |
| `.github/workflows/widevine-elf-audit.yml` | **KEEP + CORRECT gate** | Green CI proves manifest/targeted checkout and ELF static inspection only; **not** A15 Soong/VINTF/SELinux build. Remove the CI assertion treating absence of `hdcpd` as a permanent desired invariant; audit the actual Celadon bridge instead. |
| `hdcp/README.md` | **CORRECT architecture claims** | Source-only status is accurate. Claims that an `hdcpd` bridge would compete with HWC or necessarily be unused are unsupported in the presence of Celadon's HWC-integrated design. Keep one-HWC constraint and real HDCP proof criteria. |

### D. Exhaustive changed-file disposition (device PR #10)

| Changed file | Decision | Evidence / exact required follow-up |
|---|---|---|
| `r86s_virtio_tv/device.mk` | **KEEP i915; CORRECT exclusion rationale** | `ro.vendor.graphics.gpu=i915` matches the actual Lineage init selector. Removing inert `libhdcpsdk` is acceptable as an *interim non-functional-HDCP draft state*, not an argument to exclude Celadon's daemon/SDK from the intended final implementation. |
| `r86s_virtio_tv/BoardConfig.mk` | **KEEP; BUILD GATE** | R86S-only `BOARD_VENDOR_SEPOLICY_DIRS` wiring is appropriate; compile against all inherited vendor policy directories and detect type clashes/neverallows. |
| `r86s_virtio_tv/sepolicy/vendor/file_contexts` | **KEEP; BUILD/RUNTIME GATE** | Escaped executable dots and data path labels match the vendor prebuilt's intended service/data paths. Verify actual installed file context and transition. |
| `r86s_virtio_tv/sepolicy/vendor/service_contexts` | **KEEP; BUILD/RUNTIME GATE** | AIDL `android.hardware.drm.IDrmFactory/widevine` label matches the prebuilt VINTF/rc intent. Verify binder registration and selinux rights. |
| `r86s_virtio_tv/sepolicy/vendor/hal_drm_widevine.te` | **KEEP scaffolding, REASSESS missing rules** | Defines AIDL DRM HAL domain and mediadrm data type/access. Other prebuilt policies include GPU, Composer, fd/binder, tmpfs, and HDCP permissions. Re-add only where justified and prove with Soong/neverallow/AVC and actual operation; do not use absence of ELF `DT_NEEDED` to dismiss HDCP communication. |

### E. Verification status, ordered blocking gates

| Gate | Status | Pass/fail standard |
|---|---|---|
| Source trace / all 11 PR changed files | **COMPLETED (this audit)** | All file dispositions above, authoritative source references below |
| Existing tools workflow at `547ce5d` (run `39151843286`) | **PASS, STATIC ONLY** | Manifest resolve, pin checkout, shell/XML and ELF analysis |
| Verified pinned Widevine binary actually packaged | **OPEN** | Pin production manifest and check installed SHA |
| A15 Soong + vendor SELinux + VINTF | **OPEN** | Full Android 15 build on correct combined source tree, no policy/compiler failures |
| R86S passthrough / kernel | **OPEN** | In-guest Intel GPU/i915, appropriate MEI, connector exposure, host IOMMU proof |
| Widevine L3 | **OPEN** | MediaDrm factory, L3 openSession, valid HDCP-free license, encrypted video decoded |
| HDCP | **OPEN** | Protection request from real license policy → DRM/KMS `Desired`→`Enabled`, correct version, link loss/reset and failed-safe playback |

**No claim:** source audit cannot prove actual build, HDCP handshake, runtime L3, or HDCP2.2. These are separate milestones beyond this audit.

### F. Primary source pointers

- Pinned HDCP [README](https://github.com/projectceladon/hdcp/blob/ccd30e43b3205e22aff9d2aa09a11aa0d4f3870d/README.md), [Android.bp](https://github.com/projectceladon/hdcp/blob/ccd30e43b3205e22aff9d2aa09a11aa0d4f3870d/daemon/Android.bp), [portmanager](https://github.com/projectceladon/hdcp/blob/ccd30e43b3205e22aff9d2aa09a11aa0d4f3870d/daemon/portmanager_android.cpp).
- Celadon HWC [Binder bridge](https://github.com/projectceladon/drm-hwcomposer/blob/main/hwc2_device/hwcservice.cpp), [HWC2 HDCP methods](https://github.com/projectceladon/drm-hwcomposer/blob/main/hwc2_device/DrmHwcTwo.cpp), [ResourceManager](https://github.com/projectceladon/drm-hwcomposer/blob/main/drm/ResourceManager.cpp), [DRM state](https://github.com/projectceladon/drm-hwcomposer/blob/main/drm/DrmAtomicStateManager.cpp).
- Lineage 22.1 [i915 init](https://github.com/LineageOS/android_device_virt_virtio_x86_64/blob/lineage-22.1/configs/init/virtio_x86_64-graphics.rc), [HWC3 build](https://github.com/LineageOS/android_device_virt_virtio_x86_64/blob/lineage-22.1/hals/hwcomposer/drm/Android.bp).
- Pinned Widevine [prebuilt Android.bp](https://github.com/supremegamers/vendor_google_proprietary_widevine-prebuilt/blob/47992c25673ed766155fc52d0e6ae81d9769a06c/Android.bp), [SELinux](https://github.com/supremegamers/vendor_google_proprietary_widevine-prebuilt/blob/47992c25673ed766155fc52d0e6ae81d9769a06c/sepolicy/gen/gen_common/hal_drm_widevine.te).
- [Official Celadon Widevine L3 guide](https://projectceladon.github.io/celadon-documentation/tutorials/widevine-integration.html) (older HIDL-era examples: do not directly transplant into A15 AIDL).
- [Existing static CI](https://github.com/kazuki0824/android_device_maleicacid_androidtv_tools/actions/runs/39151843286).

## G. Requirement refinement (2026-11-16): existing HWC2 internals are allowed

The original audit's phrase *"strict HWC3-only"* and the milestone *"HWC2 runtime/internal dependency removed"* **are superseded** by the user's actual requirement:

- Keep LineageOS's existing AIDL HWC3 service and all internal HWC2-derived code it already uses.
- **Do not add new HWC2 dependencies** solely for Widevine L3 or HDCP. Do not install a new HWC2 HAL service, use Celadon's HWC2-to-HWC3 adapter as an HDCP integration, or add an HWC2-specific `libhwcservice` bridge.
- This requirement does not mandate removal or renaming of upstream `external/drm_hwcomposer/hwc2_device` code. The upstream HWC3 service already imports HWC2-derived display methods and types; that remains supported as part of the baseline.
- The new code, if necessary, belongs in the one existing HWC3/DRM/KMS owner after a valid Android 15 policy-to-HDCP request path has been established.
- The only permitted acceptance statement at this stage is *design and static manifest checks*, **not** that physical HDMI HDCP or Widevine encrypted media playback works.

The controlling specification is [HWC3_ONLY_DESIGN.md](HWC3_ONLY_DESIGN.md). This note is an explicit correction to previous sections of this historical source audit.
