#!/usr/bin/env python3
"""Distinguish Linux source Kconfig evidence from the running kernel config."""
import argparse
import gzip
import re
from pathlib import Path

SYMBOLS = ("CONFIG_DRM", "CONFIG_DRM_I915", "CONFIG_INTEL_MEI",
           "CONFIG_INTEL_MEI_ME", "CONFIG_INTEL_MEI_HDCP",
           "CONFIG_VFIO", "CONFIG_VFIO_PCI", "CONFIG_INTEL_IOMMU")


def text(path):
    f = Path(path)
    if f.suffix == ".gz":
        with gzip.open(f, "rt", errors="replace") as fp:
            return fp.read()
    return f.read_text(errors="replace")


def config(path):
    found = {}
    for line in text(path).splitlines():
        m = re.fullmatch(r"(CONFIG_[A-Z0-9_]+)=(.+)", line)
        if m:
            found[m.group(1)] = m.group(2)
        m = re.fullmatch(r"# (CONFIG_[A-Z0-9_]+) is not set", line)
        if m:
            found[m.group(1)] = "n"
    return found


def table(values, section):
    print("\n## " + section)
    print("| Symbol | Status in supplied config |")
    print("|---|---|")
    for key in SYMBOLS:
        print("| " + key + " | " + values.get(key, "NOT SPECIFIED") + " |")


def main():
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest="mode", required=True)
    s = sub.add_parser("source")
    for arg in ("base", "passthrough", "mei-core-kconfig", "mei-hdcp-kconfig",
                "i915-kconfig", "hdcp-code", "board-config", "kernel-selection"):
        s.add_argument("--" + arg, required=True)
    e = sub.add_parser("effective")
    e.add_argument("--config", required=True)
    e.add_argument("--role", required=True, choices=("host", "guest"))
    e.add_argument("--hdcp22", action="store_true")
    args = p.parse_args()

    if args.mode == "source":
        base = config(args.base)
        gpu = config(args.passthrough)
        mei_core = text(args.mei_core_kconfig)
        mei_hdcp = text(args.mei_hdcp_kconfig)
        i915 = text(args.i915_kconfig)
        hdcp = text(args.hdcp_code)
        board = text(args.board_config)
        kernel = text(args.kernel_selection)
        errors = []
        if base.get("CONFIG_DRM") not in ("y", "m"):
            errors.append("DRM not enabled in gki_defconfig")
        if gpu.get("CONFIG_DRM_I915") not in ("y", "m"):
            errors.append("DRM_I915 not enabled in GPU passthrough fragment")
        for k in ("INTEL_MEI", "INTEL_MEI_ME"):
            if not re.search(r"^config " + k + r"\s*$", mei_core, re.M):
                errors.append("Missing " + k + " Kconfig")
        if not re.search(r"config INTEL_MEI_HDCP[\s\S]*?select INTEL_MEI_ME[\s\S]*?depends on DRM_I915", mei_hdcp):
            errors.append("Unexpected HDCP MEI Kconfig dependencies")
        if "select DRM_DISPLAY_HDCP_HELPER" not in i915:
            errors.append("i915 HDCP helper selection not found")
        if "IS_ENABLED(CONFIG_INTEL_MEI_HDCP)" not in hdcp:
            errors.append("i915 code no longer gates HDCP 2.x on MEI HDCP")
        if "lineageos/peripheral/passthrough_gpus.config" not in board:
            errors.append("BoardConfig does not select GPU passthrough fragment")
        if "TARGET_PREBUILT_EMULATOR_KERNEL_USE" not in kernel or "TARGET_KERNEL_SOURCE" not in kernel:
            errors.append("Kernel prebuilt/source fallback not found")
        print("# Android guest i915 / MEI HDCP source-only audit")
        table(base, "GKI defconfig")
        table(gpu, "GPU passthrough overlay")
        print("\nCONTRACT: INTEL_MEI_HDCP depends on DRM_I915 and selects INTEL_MEI_ME.")
        print("CONTRACT: i915 HDCP 2.x path checks IS_ENABLED(CONFIG_INTEL_MEI_HDCP).")
        print("WARNING: the Android product can use a prebuilt 6.6 kernel.")
        print("NOT PROVEN: final .config, installed modules, PCI/MEI passthrough, HDMI.")
        unknown = [x for x in ("CONFIG_INTEL_MEI", "CONFIG_INTEL_MEI_ME",
                               "CONFIG_INTEL_MEI_HDCP") if x not in base and x not in gpu]
        print("UNSPECIFIED IN INSPECTED FRAGMENTS: " + ", ".join(unknown))
        if errors:
            raise SystemExit("SOURCE CONTRACT FAIL: " + "; ".join(errors))
        print("PASS: source wiring and Kconfig contracts only; effective kernel is UNVERIFIED.")
        return

    values = config(args.config)
    print("# Effective .config supplied for " + args.role)
    print("Evidence file: " + args.config)
    table(values, "Effective kernel symbols")
    needed = ["CONFIG_VFIO", "CONFIG_VFIO_PCI", "CONFIG_INTEL_IOMMU"] if args.role == "host" else ["CONFIG_DRM", "CONFIG_DRM_I915"]
    if args.role == "guest" and args.hdcp22:
        needed.extend(["CONFIG_INTEL_MEI", "CONFIG_INTEL_MEI_ME", "CONFIG_INTEL_MEI_HDCP"])
    missing = [k for k in needed if values.get(k) not in ("y", "m")]
    if missing:
        print("FAIL / NOT PROVEN: " + ", ".join(missing))
        print("Note: omitted symbols in partial configs are unknown, not automatically disabled.")
        raise SystemExit(1)
    print("PASS: required options are enabled in the provided effective .config.")
    print("NOT PROVEN: needed modules load, MEI device is in guest, physical HDCP Enabled, license enforcement.")


if __name__ == "__main__":
    main()
