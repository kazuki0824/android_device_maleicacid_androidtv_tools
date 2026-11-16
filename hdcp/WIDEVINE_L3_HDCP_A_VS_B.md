# R86S Android 15 — Widevine L3 HDCP capability / policy audit and A-vs-B decision

Original investigation: 2026-11-16. This file records static evidence and the A/B architectural decision; the current limited product implementation is noted below. Widevine L1 excluded. Existing LineageOS 22.1 HWC3 (including its pre-existing HWC2-derived internals) is retained, **without adding new HWC2 dependencies**.

## 1. Evidence: pinned vendor Widevine, not generic assumptions

**Static audit snapshot:** [supremegamers/vendor_google_proprietary_widevine-prebuilt @ 47992c25673ed766155fc52d0e6ae81d9769a06c](https://github.com/supremegamers/vendor_google_proprietary_widevine-prebuilt/tree/47992c25673ed766155fc52d0e6ae81d9769a06c). The product tools manifest instead tracks the **celadon branch**, intentionally without a SHA pin. This historical CI evidence applies to that snapshot, not necessarily to future branch heads.

[Actual prior CI ELF audit logs](https://github.com/kazuki0824/android_device_maleicacid_androidtv_tools/actions/runs/43860459565), **not guessed implementation behavior**:

- `libwvaidl.so` contains mangled function-name strings for `WVDrmPlugin::getHdcpLevels`, `CryptoSession::GetHdcpCapabilities`, `PolicyEngine::CheckDeviceHdcpStatus`, `PolicyEngine::CheckDeviceHdcpStatusOnTimer`, `LicenseKeys::ApplyConstraints`, and `LicenseKeyStatus::ApplyConstraints`.
- It contains `ERROR_INSUFFICIENT_HDCP`, `GetHDCPCapability`, `GET_HDCP_CAPABILITY_FAILED`, `HDCP_NONE`, `HDCP_V1_4`, `HDCP_V2_2`, `HDCP_V2_3` and an error saying that key use is prohibited when HDCP or resolution requirements are not met.
- The main HAL executable also has `MeetsHdcpRequirements` and HDCP-level reporting/diagnostics literals.
- Neither binary directly links `libhdcpsdk` or `libhwcservice` via `DT_NEEDED`, nor contains plain `hdcpd`/`hwc.info`/`.sdk_socket` references. Both import `dlopen`/`dlsym`; **absence of direct linkage does not rule out runtime calls**.
- `liboemcrypto.so` appears as a load candidate, while this prebuilt repository does not ship it. The exact **L3 fallback** path and capability reporting on Android 15 are not established.

**Interpretation:** There is credible compiled-in HDCP capability/policy logic, which refutes the assumption that this Widevine implementation has no such code. **Not proved**: that any function is executed on the L3 path, where real connector state comes from, that reported negotiated level matches i915/KMS, that failure/loss of protection makes content undecryptable, or that a given HDCP-restricted Widevine L3 license will be accepted. These require a running HAL and real test licenses, not additional string matching.

## 2. External contracts and separate levels of success

- [Android 15 IDrmPlugin AIDL `getHdcpLevels()`](https://github.com/LineageOS/android_hardware_interfaces/blob/lineage-22.1/drm/aidl/android/hardware/drm/IDrmPlugin.aidl): current and maximum HDCP levels are **informational**; **DRM system**, not the app-side getter, must enforce output policy. Multiple displays: current level is the minimum across attached HDCP-capable interfaces.
- [Android MediaDrm getConnectedHdcpLevel](https://developer.android.com/reference/android/media/MediaDrm#getConnectedHdcpLevel()): informational, **not** an authorization or HDCP trigger.
- [Linux DRM/KMS Content Protection](https://www.kernel.org/doc/html/latest/gpu/drm-kms.html): userspace requests `Desired`, kernel reports `Enabled`; loss is `Enabled → Desired` and may emit a uevent. The `HDCP Content Type` selector has type-0/type-1 semantics, **not a trustworthy standalone report of the exact negotiated version**.
- [Chromium 2026-09-05 commit](https://chromium.googlesource.com/chromium/src/media/+/a42d1bc9bf64e6709dc309cf0cc5794024af3cce) and [current Chromium Android bridge](https://chromium.googlesource.com/chromium/src/+/main/media/base/android/media_drm_bridge.cc): Chromium explicitly treats `SW_SECURE_CRYPTO`/Widevine L3 as **unable to enforce hardware HDCP output protection** and reports no HDCP for its EME policy path. **This is evidence for the Chromium policy implementation**, not direct proof of this vendor library's behavior or universal impossibility of independent HDCP alongside L3.
- Google [Widevine output-control guidance](https://support.google.com/widevine/answer/6072641?hl=en) notes that license policies can require HDCP. The licence policy is not itself an Android HWC3 command API.

Acceptance criteria remain separate:

1. **Widevine L3**: actual L3 session/provisioning, HDCP-free licensed *encrypted* playback.
2. **Standalone HDCP**: R86S guest i915 controls a physical connector, `Content Protection` goes `Desired → Enabled`, and link-loss/re-authentication behave correctly.
3. **Combined protected license**: DRM plugin actually recognizes current/max HDCP, enforces minimum required policy with no protected-frame disclosure on link loss, and HDCP-restricted Widevine L3 test content plays (or is correctly rejected with the limitation recorded). **Do not silently call (1)+(2) proof of (3)**.

## 3. Scheme selection — A vs B

| Criterion | A: initiate HDCP independently on supported physical connector | B: request HDCP in response to protected-license/playback needs |
|---|---|---|
| Requires a new license-to-HWC command path | **No** for link authentication | **Yes**, unless an existing supported path is identified |
| Android 15 Composer AIDL issue | No need to invent `startHdcpNegotiation` | AIDL lacks this later method; suitable authorized request source unverified |
| HWC2 dependency increase | Not required; use existing HWC3-owned DRM/KMS | Not required in principle, but must not import Celadon's HWC2 bridge |
| HDCP link handshakes | Can be verified independently of Widevine | Coupled to an unverified trigger |
| HDCP license enforcement | **Not guaranteed** by link being Enabled | **Not guaranteed** by trigger alone |
| Additional complexity | Low relative to B; connector lifetime/state is still necessary | Higher: lifecycle, policy interpretation, request channel |
| Decision | **Preferred first HDCP implementation candidate** | **Not justified as a prerequisite**; revisit only if A is demonstrably insufficient |

**Decision:** Use **A** as the **link-level HDCP strategy** when hardware supports KMS Content Protection. Request through the existing single DRM-master/HWC3 owner on a valid active physical connector, not from a second independent KMS writer. Default to Type0 when no stronger verified content policy is known; do not claim Type0 proves 2.2, and do not turn every connected digital output into a forced Type1. Monitor `Desired/Enabled`, hotplug and reauthentication; never forge an HDCP level to the DRM plugin. Do not insert any new HWC2 bridge.

**Crucial constraint:** A does **not** solve the unknown vendor-L3 DRM policy enforcement path. Do not build a new B path based on an invented API, do not patch OEMCrypto/securityLevel to lie, and do not claim HDCP-required content support at L3 until a test demonstrates it. If Widevine L3 returns `HDCP_NONE` or rejects the license, that may be the correct implementation constraint even while the HDMI link itself is encrypted. L1 is outside scope.

## 4. Work boundaries

- **Step 1 completed:** code/symbol/static-audit evidence and Android contract recorded. Runtime truth remains an explicitly separate test gate.
- **Step 2 completed as architecture selection:** A preferred for independent physical HDCP; B deferred. A one-shot, best-effort `Content Protection=Desired` request is now present in product PR #15, but its application, compilation and hardware behavior still require proof.
- **Still not performed:** Android 15 Soong build, SELinux/VINTF build, hardware HDCP validation, tests involving licensed material and GPU passthrough investigation. The existing HWC3 patch is source-only until its build and runtime behavior are verified.

The next gates are: validate the existing HWC3 patch against the A15 source and compile it; run L3 HAL tests; measure host `lspci -nnk`, IOMMU groups and `uname -a`; then guest KMS connector properties, `Desired → Enabled`, reauthentication and actual L3 HDCP-level reports. Host data is for feasibility and test selection, **not hard-coded PCI IDs**.

## 5. Deeper ELF evidence generated by GitHub Actions (2026-11-16)

A read-only workflow now reproduces **both a raw string/dynamic-symbol distinction and a bounded call-edge inspection**, using SHA-256 verified files from the pinned Widevine commit. [Workflow run 43864251441](https://github.com/kazuki0824/android_device_maleicacid_androidtv_tools/actions/runs/43864251441) succeeded and published the `widevine-hdcp-static-evidence` artifact. Its two entrypoints are [deep_audit_widevine_hdcp.py](deep_audit_widevine_hdcp.py) and [inspect_widevine_hdcp_call_edges.py](inspect_widevine_hdcp_call_edges.py).

**Both ELF files are stripped and lack `.symtab`; `libwvaidl.so` nevertheless exports useful defined dynamic symbols in `.dynsym`.** This is stronger than finding text strings, but still not runtime proof.

| Observation | Static finding | Confidence / limit |
|---|---|---|
| `WVDrmPlugin::getHdcpLevels` | Defined `FUNC` in `.dynsym`, 375 bytes at `0x1c4970` | Disassembly shows **direct calls to `WVDrmPlugin::queryProperty`**; exact property source/value and L3 behavior not proven |
| `CryptoSession::GetHdcpCapabilities(RequestedSecurityLevel,...)` | Defined `FUNC`, 637 bytes at `0x132c50` | Direct call to `wvcdm::_oecc44` (an internal dispatch-like routine); actual hardware and fallback path not established |
| `PolicyEngine::CheckDeviceHdcpStatus` and `...OnTimer` | Defined `FUNC` symbols, 177/209 bytes | Contains indirect calls; the caller/liveness and the handling of changing HDMI HDCP state were not established |
| `LicenseKeys::ApplyConstraints` and `LicenseKeyStatus::ApplyConstraints` | Defined `FUNC` symbols, 121/392 bytes | License constraint code exists; cannot prove it runs in Widevine L3 or enforces output HDCP on this system |
| `libhdcpsdk`, `libhwcservice`, `hdcpd`, `hwc.info`, `.sdk_socket` | No `DT_NEEDED` or symbol/string references in the audited binaries | Excludes these *direct textual/static dependencies*, not indirect `dlopen` or other IPC |
| `liboemcrypto.so` | HAL executable includes a string indicating fallback to L3 if its version is unsuitable | Not proof L3 succeeds without OEMCrypto or reports real HDCP |

The disassembly **does not resolve an actual current HDCP level source (KMS, OEMCrypto, placeholder or constant)** and cannot establish output-policy compliance. No code in this audit was executed on Android or R86S. In particular, do not equate the exported `WVDrmPlugin::getHdcpLevels` method with successful physical HDCP reporting.

**Effect on decision:** No change to choosing **A first for independent link authentication** and deferring B as an unsubstantiated extra integration. A+B are not substitutes for runtime checks of protected-license enforcement, and a DRM L3 implementation that refuses HDCP-required content must not be bypassed by forging status.
