#!/usr/bin/env python3
"""Read-only evidence audit of two PINNED Widevine ELF files.

This does not execute proprietary binaries or infer actual L3 runtime behavior.
Outputs a Markdown report for the GitHub Actions job summary/artifact.
"""
from __future__ import annotations

import hashlib
import os
import re
import subprocess
import sys
import tempfile
import urllib.request
from pathlib import Path

REV = "47992c25673ed766155fc52d0e6ae81d9769a06c"
BASE = f"https://raw.githubusercontent.com/supremegamers/vendor_google_proprietary_widevine-prebuilt/{REV}"
FILES = {
    "android.hardware.drm-service.widevine": "b4b71fc93ab5f8e014e682d0c8a833085cf641072d2c8cab4e0a65fd1f810860",
    "libwvaidl.so": "f609885e2e2285dde0524ed430ad31e445d6e85d1c4e2824067bda015d1415b1",
}
PROBES = (
    ("getHdcpLevels", "AIDL informational HDCP-level method"),
    ("GetHdcpCapabilities", "OEMCrypto capability query"),
    ("GetHDCPCapability", "HDCP capability API text"),
    ("CheckDeviceHdcpStatus", "policy engine HDCP status check"),
    ("CheckDeviceHdcpStatusOnTimer", "periodic policy recheck"),
    ("ApplyConstraints", "license key restriction evaluation"),
    ("MeetsHdcpRequirements", "HDCP policy test"),
    ("ERROR_INSUFFICIENT_HDCP", "insufficient output protection"),
    ("liboemcrypto.so", "dynamic OEMCrypto candidate"),
    ("hdcpd", "legacy Celadon daemon string"),
    ("libhdcpsdk", "legacy Celadon SDK string"),
    ("libhwcservice", "Celadon HWC binder bridge string"),
    ("hwc.info", "Celadon bridge service string"),
    (".sdk_socket", "Celadon HDCP socket string"),
)
DIRECT = ("libhdcpsdk", "libhwcservice", "hdcpd", "hwc.info", ".sdk_socket")
MAX_LINE = 155


def run(*args: str) -> str:
    p = subprocess.run(args, check=True, capture_output=True, text=True)
    return p.stdout


def fetch(file: str, output: Path, expected_sha256: str) -> str:
    request = urllib.request.Request(f"{BASE}/{file}", headers={"User-Agent": "R86S-Widevine-static-audit/1"})
    with urllib.request.urlopen(request, timeout=90) as src, output.open("wb") as dst:
        while True:
            block = src.read(1 << 20)
            if not block:
                break
            dst.write(block)
    h = hashlib.sha256(output.read_bytes()).hexdigest()
    if h != expected_sha256:
        raise RuntimeError(f"Unexpected bytes for {file}: SHA256={h}; expected={expected_sha256}")
    return h


def main() -> None:
    out = Path(os.environ.get("HDCP_AUDIT_REPORT", "widevine-hdcp-static-evidence.md"))
    lines = [
        "# Pinned Widevine ELF: HDCP policy evidence",
        "",
        f"Source commit: [`{REV}`](https://github.com/supremegamers/vendor_google_proprietary_widevine-prebuilt/tree/{REV}).",
        "",
        "**Method:** Download exact SHA-256 checked ELF files; inspect `readelf` metadata,",
        "`DT_NEEDED`, dynamic/full symbol tables, and offset-labelled raw string occurrences.",
        "No binary is run. A symbol-like string is **not** evidence of an exported symbol,",
        "reachable function, real HDCP level, or active L3 license enforcement.",
        "",
    ]
    with tempfile.TemporaryDirectory(prefix="widevine-elf-audit-") as temp:
        for name, expected in FILES.items():
            file = Path(temp) / name
            h = fetch(name, file, expected)
            header = run("readelf", "-hW", str(file))
            sections = run("readelf", "-SW", str(file))
            dynamic = run("readelf", "-dW", str(file))
            dynsyms = run("readelf", "--dyn-syms", "-W", str(file)).splitlines()
            raw = run("strings", "-a", "-t", "x", str(file)).splitlines()
            has_symtab = bool(re.search(r"\]\s+\.symtab\s", sections))
            needed = re.findall(r"Shared library: \[([^\]]+)\]", dynamic)
            lines += [
                f"## `{name}`",
                "",
                f"- SHA-256: `{h}`",
                f"- Size: {file.stat().st_size} bytes",
                f"- ELF: {next((l.strip() for l in header.splitlines() if 'Machine:' in l), '?')}",
                f"- `.symtab`: {'present' if has_symtab else 'absent (stripped; full symbol/call graph unavailable)'}",
                f"- `DT_NEEDED`: {', '.join(f'`{lib}`' for lib in needed) or 'none'}",
                "",
                "| Probe | Defined dynamic symbol | Undefined dynamic symbol | Raw strings |",
                "|---|---:|---:|---:|",
            ]
            for token, purpose in PROBES:
                symbols = [l for l in dynsyms if token.casefold() in l.casefold()]
                defined = sum(1 for l in symbols if not re.search(r"\sUND\s", l))
                undefined = len(symbols) - defined
                raw_hits = [l for l in raw if token.casefold() in l.casefold()]
                lines.append(f"| `{token}` | {defined} | {undefined} | {len(raw_hits)} |")
            lines += [
                "",
                "### Reproducible examples (first two raw strings per probe)",
                "",
            ]
            for token, purpose in PROBES:
                raw_hits = [l.strip() for l in raw if token.casefold() in l.casefold()]
                if raw_hits:
                    lines.append(f"- **{purpose}** (`{token}`):")
                    for hit in raw_hits[:2]:
                        lines.append(f"  - `{hit[:MAX_LINE].replace(chr(96), chr(39))}`")
            lines += [
                "",
                "### Direct external-library dependency check",
                "",
            ]
            for token in DIRECT:
                direct_needed = any(token.casefold() in lib.casefold() for lib in needed)
                dyn = [x.strip()[:MAX_LINE] for x in dynsyms if token.casefold() in x.casefold()]
                lines.append(f"- `{token}`: DT_NEEDED={'yes' if direct_needed else 'no'}, dynamic-symbol matches={len(dyn)}.")
            lines += [
                "",
                "**Interpretation:** Dynamic-table absence does not exclude `dlopen`,",
                "indirect IPC, internal code paths, or license policies. A raw string",
                "is not proof that a feature is active at `SW_SECURE_CRYPTO` / Widevine L3.",
                "",
            ]
    lines += [
        "## Architecture impact",
        "",
        "1. L3 HDCP policy support remains **unverified** until Android runtime can",
        "   report a real current/maximum HDCP level and accept or correctly reject",
        "   a licensed test stream at that level.",
        "2. Independent DRM/KMS HDCP negotiation (scheme A) is a possible **link-only**",
        "   first implementation; do not assert that it enforces a Widevine L3 license.",
        "3. License-triggered negotiation (scheme B) has no proven Android 15 request",
        "   path; do not add one based solely on string and symbol inspection.",
        "4. No new HWC2 integration dependencies. The LineageOS HWC3 service's",
        "   existing HWC2-derived internals are explicitly permitted.",
        "",
    ]
    content = "\n".join(lines) + "\n"
    out.write_text(content)
    print(content)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as f:
            f.write(content)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"Widevine HDCP static evidence audit failed: {exc}", file=sys.stderr)
        raise
