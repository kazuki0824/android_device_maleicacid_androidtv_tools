#!/usr/bin/env python3
"""Bounded disassembly of a pinned Widevine ELF (never executes it)."""
import hashlib
import os
import re
import subprocess
import sys
import tempfile
import urllib.request
from pathlib import Path

COMMIT = "47992c25673ed766155fc52d0e6ae81d9769a06c"
NAME = "libwvaidl.so"
HASH = "f609885e2e2285dde0524ed430ad31e445d6e85d1c4e2824067bda015d1415b1"
TOKENS = ("getHdcpLevels", "GetHdcpCapabilities", "CheckDeviceHdcpStatus", "ApplyConstraints")
MAX_SYMBOLS = 15
MAX_INSNS_BYTES = 2048


def command(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout


def main():
    report_path = Path(os.environ.get("HDCP_DISASM_REPORT", "widevine-hdcp-call-edges.md"))
    request = urllib.request.Request(
        f"https://raw.githubusercontent.com/supremegamers/vendor_google_proprietary_widevine-prebuilt/{COMMIT}/{NAME}",
        headers={"User-Agent": "R86S-HdcpCallEdges/1"},
    )
    with tempfile.TemporaryDirectory(prefix="wv-static-") as temp:
        target = Path(temp) / NAME
        with urllib.request.urlopen(request, timeout=90) as data, target.open("wb") as output:
            while True:
                chunk = data.read(1024 * 1024)
                if not chunk:
                    break
                output.write(chunk)
        checksum = hashlib.sha256(target.read_bytes()).hexdigest()
        if checksum != HASH:
            raise RuntimeError("Pinned Widevine content checksum mismatch")

        symbols = command("readelf", "--dyn-syms", "-W", str(target)).splitlines()
        candidates = []
        rx = re.compile(r"^\s*\d+:\s+([0-9a-fA-F]+)\s+(\d+)\s+FUNC\s+\S+\s+\S+\s+(\S+)\s+(\S+)")
        for line in symbols:
            m = rx.match(line)
            if not m or m[3] == "UND" or not any(tok in m[4] for tok in TOKENS):
                continue
            addr, size, section, mangled = int(m[1], 16), int(m[2]), m[3], m[4]
            if addr and size:
                candidates.append((mangled, addr, size, section))

        lines = [
            "# Pinned Widevine static HDCP call-edge evidence",
            "",
            f"- Source SHA: {COMMIT}; binary: {NAME}; SHA-256: {HASH}",
            f"- Defined dynamic-symbol candidates: {len(candidates)}",
            "- Approximate direct-call listing, NOT a complete call graph.",
            "- Stripped ELF: hidden functions and indirect calls cannot be resolved.",
            "- Runtime L3 dispatch, negotiated HDCP level and license behavior are NOT proven.",
            "",
        ]
        for mangled, addr, size, section in candidates[:MAX_SYMBOLS]:
            human = command("c++filt", mangled).strip()
            end = addr + min(size, MAX_INSNS_BYTES)
            disas = command("objdump", "-d", "-C", "-M", "intel",
                            f"--start-address=0x{addr:x}",
                            f"--stop-address=0x{end:x}", str(target))
            calls = []
            for line in disas.splitlines():
                if re.search(r"\b(call|jmp)\s", line) and re.match(r"^\s*[0-9a-fA-F]+:", line):
                    clean = line.strip().split("\t")[-1]
                    if clean not in calls:
                        calls.append(clean[:180])
            lines += [
                f"## {human}",
                "",
                f"- Dynamic symbol address: 0x{addr:x}; size: {size} bytes; section: {section}.",
                f"- Disassembly inspected: {min(size, MAX_INSNS_BYTES)} bytes; direct call/jump instructions: {len(calls)}.",
                "",
            ]
            if calls:
                lines += ["    " + line for line in calls[:22]]
                lines.append("")
            else:
                lines += ["No directly decoded call/jump instructions in the bounded region.", ""]

        if not candidates:
            raise RuntimeError("Missing expected defined HDCP dynamic symbols")
        lines += [
            "## Architectural decision",
            "",
            "Scheme A can authenticate the physical link without a license-triggered request.",
            "Nothing in these call edges proves Widevine L3 output policy enforcement.",
            "Scheme B cannot be justified from static symbols alone.",
            "",
        ]
        content = "\n".join(lines)
        report_path.write_text(content, encoding="utf-8")
        print(content)
        summary = os.environ.get("GITHUB_STEP_SUMMARY")
        if summary:
            with open(summary, "a", encoding="utf-8") as out:
                out.write(content)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"Static call-edge inspection failed: {exc}", file=sys.stderr)
        raise
