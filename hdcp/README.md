# R86S HDCP source and product integration — Android 15

This PR is stacked on #12 and pairs with
[kazuki0824/virtio_x86_64_tv_grub#10](https://github.com/kazuki0824/virtio_x86_64_tv_grub/pull/10).
The tools repository owns the optional R86S local manifest; the device repository
owns product-specific package selection. No post-sync edits to another repository.

## Integration

When `ANDROID_PRODUCT=r86s_virtio_tv`, `get_android_qcow2.sh` copies
`hdcp/93-hdcp.xml` as `.repo/local_manifests/zz-hdcp.xml` before
`repo sync`. Its local filename is deliberately sorted after
`virtio_x86_64_tv_grub.xml` so `extend-project` can find the project.
The manifest pins Celadon's HDCP source snapshot at
`ccd30e43b3205e22aff9d2aa09a11aa0d4f3870d`.
For the R86S build, the same manifest uses `extend-project` to pin the
companion device PR #10 commit and its upstream branch. The default QEMU
product continues to use the device repository's `main`.
`libhdcpsdk` is **not yet** installed. This is a source-only interim state,
not a decision that HDCP clients/daemon are unnecessary. The R86S product
currently defines limited Widevine L3 SELinux permissions; missing rights
must be tested in a real Android 15 build and at runtime. The Widevine
prebuilt is pinned to the same revision used by the ELF scanner.

## Important: not yet end-to-end HDCP

The existing LineageOS 22.1 AIDL HWC3 service is retained, including
its upstream internal HWC2-derived display/layer implementation.
**Our feature must not add any new HWC2 service, adapter, frontend or HWC2
library dependency**. Celadon's `hdcpd` uses `libhwcservice` to call its
HWC2 frontend, not to launch a second DRM master; that legacy bridge cannot
be installed unchanged for this product. A future connector-control
integration must use the existing single HWC3-owned DRM/KMS path.

The HDCP source is present for inspection and future implementation only.
It is not an installed or running service. Current status: source/product
integration, not functioning HDCP.

## Validation

On Android: `bash hdcp/check_android_drm.sh` runs read-only diagnostics.
It **does not** prove a Widevine DRM session or decryption.

On bare-metal R86S: `sudo modetest -M i915 -c` and kernel logs must show
a real HDMI connector supporting content protection, with the state advancing
from Desired to Enabled during a valid authentication. i915/MEI/firmware and the
sink must be compatible.

Widevine L3 acceptance independently requires a `MediaDrm` test APK:
recognize Widevine scheme UUID
`edef8ba9-79d6-4ace-a3c8-27dcd51d21ed`,
successfully `openSession()`, and then use Media3 ExoPlayer to acquire
an explicitly HDCP-free Widevine license and decode actually encrypted
video frames. Clear MP4 and ClearKey are not equivalent.

## Still required

1. Confirm A15 HWC's DRM connector properties and secure-layer metadata
   path before implementing an HDCP request mechanism.
2. Keep the existing LineageOS 22.1 HWC3/DRM code unchanged, even where it
   internally uses HWC2-derived code. Integrate HDCP only through the existing
   DRM/KMS owner, without adding any new HWC2 service/adapter/bridge. Establish
   a supported protection-request source and then implement missing connector
   negotiation; reuse Celadon logic where compatible.
3. Verify the R86S policy through Soong and SELinux compilation, plus actual
   Widevine L3 HAL init, DRM session and HDCP-free encrypted playback.
4. Verify protected playback and connector authentication on R86S.


## Decision: one DRM-master owner for HDCP on A15

- **Owner:** retain the existing Android 15 AIDL HWC3 DRM/KMS owner with all
  its existing internal dependencies. This feature adds no HWC2 dependency.
  Celadon's client/daemon path is not inherently a second compositor, but its
  HWC2-specific bridge must not be installed unchanged; any later HDCP
  integration must operate through the present HWC3-owned DRM/KMS path.
- **Kernel contract:** select the actual HDMI/DP connector; inspect
  `Content Protection` and optional `HDCP Content Type`. The existing
  DRM-master HWC must issue `Desired` (not `Enabled`) and independently
  observe the kernel transition to `Enabled`. Report failures or lost
  protection rather than returning synthetic success.
- **Android 15 interface:** `IComposerCallback.onHdcpLevelsChanged()` is
  available. `IComposerClient.startHdcpNegotiation()` is not in A15's
  interface; do not import A16 AIDL into A15 by editing it locally. The
  A15-compatible negotiation trigger has to be derived from the existing
  compositor's actual secure-content inputs and proven with tests.
- **Protection safety:** do not display protected buffers on unprotected
  outputs. Do not assert HDCP2.2 based solely on setting `HDCP Content Type`
  or on an IPC success. The content-license-required HDCP version and KMS
  link result must agree; otherwise playback must fail safely.
- **HDCP1.4 vs HDCP2.2:** Type0 can authenticate with 1.x or 2.x. Type1
  requires 2.x but is not in itself proof of a particular 2.x revision.
  Confirm the negotiated level through the kernel and playback policy.
- **Current limit:** no A15 HWC source implementation, A15 build, or physical
  HDMI/MEI runtime verification has been completed. Those are implementation
  and hardware acceptance work, not grounds to add an unneeded second HWC.

## Widevine binary dependency evidence

The public `celadon` service and `libwvaidl.so` are x86_64 ELF64, inspected
by `.github/workflows/widevine-elf-audit.yml`. Both use `dlopen`/`dlsym`
but neither has `DT_NEEDED` entries for `libhdcpsdk` or
`libhwcservice`; neither exposes plain ASCII/UTF-16LE tokens for the
Celadon `hdcpd`, `hwc.info`, or `.sdk_socket` transport.

Both contain the `liboemcrypto.so` dynamic-library-name candidate. It is
**not** contained in the SupremeGamers prebuilt package. A string reference
does not establish that `liboemcrypto.so` is mandatory for L3; conditional
OEMCrypto loading and fallback behavior must be tested on A15.

Static scans do not prove absence of computed library names or runtime
service/IPC dependencies. Therefore do not claim HDCP-free playback works
until MediaDrm provisioning, session open and genuinely encrypted content
decryption have all been tested.

For the no-new-HWC2 constraints and concrete architectural blockers, see
[HWC3_ONLY_DESIGN.md](HWC3_ONLY_DESIGN.md). This remains a design and source
integration draft, not functional HDCP.

**Draft; no full A15 build or hardware runtime test has been performed.**
