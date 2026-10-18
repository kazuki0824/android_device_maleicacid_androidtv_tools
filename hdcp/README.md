# R86S HDCP source and product integration — Android 15

This PR is stacked on #12 and pairs with
[kazuki0824/virtio_x86_64_tv_grub#10](https://github.com/kazuki0824/virtio_x86_64_tv_grub/pull/10).
The tools repository owns the optional R86S local manifest; the device repository
owns product-specific package selection. No post-sync edits to another repository.

## Integration

When `ANDROID_PRODUCT=r86s_virtio_tv`, `get_android_qcow2.sh` copies
`hdcp/93-hdcp.xml` into `.repo/local_manifests` before `repo sync`.
The manifest pins Celadon's Android 15 HDCP SDK sources at
`ccd30e43b3205e22aff9d2aa09a11aa0d4f3870d`.
For the R86S build, the same manifest uses `extend-project` to pin the
companion device PR #10 commit and its upstream branch. The default QEMU
product continues to use the device repository's `main`. `repo sync` failures
are fatal. `libhdcpsdk` is **not** installed: it needs Celadon's `hdcpd`
server, and no actual Widevine dependency has been demonstrated.
The R86S product provides its own Widevine L3 SELinux policy without
`hdcpd`-only permissions.

## Important: not yet end-to-end HDCP

The built-in HWC3 is selected via the existing device configuration.
Celadon's `hdcpd` uses a proprietary `libhwcservice` and `hwc.info`,
absent from that HWC3, so `hdcpd` is deliberately **not installed or started**.
No duplicate HWC, dummy SELinux types, extra Binder service or file-copy
integration has been added.

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
2. Implement only missing HWC/DRM protection negotiation in the owning
   HWC repository, without Celadon's second composer or `hwc.info` shim.
3. Verify the R86S policy through Soong and SELinux compilation, plus actual
   Widevine L3 HAL init, DRM session and HDCP-free encrypted playback.
4. Verify protected playback and connector authentication on R86S.


## Decision: one DRM-master owner for HDCP on A15

- **Owner:** keep LineageOS 22.1's existing
  `android.hardware.composer.hwc3-service.drm.virtio_x86_64` and its existing
  `external/drm_hwcomposer` DRM atomic path. Do not run a competing
  userspace HDCP daemon that writes connector properties behind HWC's back.
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

**Draft; no full A15 build or hardware runtime test has been performed.**
