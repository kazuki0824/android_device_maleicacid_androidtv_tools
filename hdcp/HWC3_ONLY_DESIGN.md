# R86S Android 15 HWC3/HDCP — current implementation and remaining contracts

**Current status, 2026-11-17:** tools product PR #15 has a narrow
`drm_hwcomposer_i915_hdcp_desired.patch` registered in
`patches/lineage-22.1/apply_patches.sh`. The patch integrates a best-effort `Content Protection=Desired` into the
existing DRM atomic frame request on an R86S/i915 HDMI-A connector. It reads
actual KMS protection state, retries if still `Undesired`, and falls back
to an unmodified frame request after a failed HDCP-added commit. It does **not**
establish that authentication reaches `Enabled`, that the request is
recovered after transient failure/link loss, or that Widevine L3 can enforce
a license requiring HDCP.

## Architecture requirements

- Keep LineageOS 22.1's existing AIDL HWC3 service and all pre-existing
  HWC2-derived internals; **no additional HWC2** HAL, bridge, adapter or
  HWC2-specific library for HDCP, and no competing DRM master.
- The HWC3/DRM/KMS source owner is `external/drm_hwcomposer`, from AOSP
  Android 15 `android-15.0.0_r14`. Its device-specific composition setup is
  owned by LineageOS `android_device_virt_virtio_x86_64`.
  The *product integration patch* is owned by tools PR #15.
- Celadon `hdcpd` depends on the HWC2-specific `libhwcservice` interface;
  its source is fetched for test-only analysis, not installed or required by
  the initial independent link-authentication scheme.
- L1 and fake secure status are out of scope.

## Separate contracts and tests

1. **A15 build:** apply product patch with `git apply --check` in the
   corresponding AOSP tag, then actually compile HWC3, Widevine AIDL HAL,
   vendor SELinux and VINTF. Patch application is not a compilation proof.
2. **HDCP link:** on physical R86S i915/HDMI, request `Desired`, read back
   `Enabled`, test disconnection and loss. Test whether the existing
   one-shot request/retry policy is sufficient. A successful KMS commit is
   not proof of HDCP authentication or version.
3. **Widevine L3:** AIDL DRM factory, session/provisioning, a genuine
   HDCP-free licensed encrypted stream and decoded video. No L1 claims.
4. **Combined policy:** a real HDCP-required test license must enforce its
   output restriction with link-state loss; independent link encryption
   alone does not prove Widevine's DRM policy honors the actual HDCP state.
5. **Android 15 API:** `IComposerCallback.onHdcpLevelsChanged` is a
   notification, not an HDCP request command; do not invent later AIDL.
   If a license-driven request channel is needed, verify it first.

## Current acceptance

| Check | State |
|---|---|
| Existing HWC3 and its HWC2-derived internals preserved | Source design, no new service added |
| HWC3-owned independent HDCP request | **Patch present in #15; compilation/runtime unverified** |
| `Desired → Enabled`, hotplug and reauth | **Unverified** |
| Widevine L3 encrypted playback | **Unverified** |
| Widevine L3 HDCP-required license enforcement | **Unverified** |
| Real Android 15 Soong + SELinux + VINTF | **Not run** |

Temporary diagnostics and CI belong to PR #22 (close unmerged).
Product code and fixes belong to tools #15 and device #10.
