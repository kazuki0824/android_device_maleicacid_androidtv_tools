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
The product-side PR #10 opts into `libhdcpsdk` when its `Android.bp` exists.
The default QEMU product does not fetch the HDCP source.

## Important: not yet end-to-end HDCP

The built-in HWC3 is selected via the existing device configuration.
Celadon's `hdcpd` uses a proprietary `libhwcservice` and `hwc.info`,
absent from that HWC3, so `hdcpd` is deliberately **not installed or started**.
No duplicate HWC, dummy SELinux types, extra Binder service or file-copy
integration has been added.

Installing `libhdcpsdk` is only a source/product integration prerequisite.
It does not prove that HDCP 1.4/2.2 can authenticate, and the SDK alone
is not a functional service.

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

1. Verify the precise built HWC3 implementation and whether it already
   reports/negotiates HDCP. Avoid inventing a second display stack.
2. Implement only missing HDCP signaling in the owning HWC repository, with
   needed SELinux and VINTF rules proven by builds/tests.
3. Verify A15 Soong build (including the `libhdcpsdk` dependency), Widevine
   L3 DRM session and HDCP-free playback.
4. Verify protected playback and connector authentication on R86S.

**Draft; no full A15 build or hardware runtime test has been performed.**
