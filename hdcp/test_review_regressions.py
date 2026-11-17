#!/usr/bin/env python3
"""Mock shell-integration tests: no Android device or Widevine ELF required."""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def run(*args, env=None, cwd=None, check=True):
    return subprocess.run(args, env=env, cwd=cwd, text=True,
                          capture_output=True, check=check)


def git(path, *args):
    return run("git", "-C", str(path), *args).stdout.strip()


def test_kms(tmp):
    bin_dir = tmp / "bin"
    bin_dir.mkdir()
    mock = bin_dir / "adb"
    mock.write_text("""#!/usr/bin/env python3
import os, sys
args=sys.argv[1:]
if not args or args[0] == "wait-for-device": sys.exit(0)
if args[0] == "shell" and len(args)>1:
    cmd=" ".join(args[1:])
    if "command -v modetest" in cmd: sys.exit(0)
    if cmd.startswith("modetest"):
        if os.environ.get("MOCK_HDCP_FAILURE") == "1":
            print("drmModeGetResources: Operation not permitted")
            sys.exit(17)
        print("  14 Content Protection:")
        print("    flags: enum")
        print("    enums: Undesired=0 Desired=1 Enabled=2")
        print("    value: 2")
        sys.exit(0)
sys.exit(0)
""")
    mock.chmod(0o755)
    env = dict(os.environ, PATH=str(bin_dir) + os.pathsep + os.environ["PATH"],
               HDCP_KMS_SAMPLES="2", HDCP_KMS_INTERVAL_SECONDS="0",
               HDCP_KMS_LOG=str(tmp / "evidence.log"))
    script = str(ROOT / "hdcp/check_android_drm.sh")
    success = run("bash", script, env=env, check=False)
    assert success.returncode == 0, success.stderr + success.stdout
    evidence = (tmp / "evidence.log").read_text()
    assert evidence.count("== KMS sample") == 2, evidence
    assert evidence.count("modetest_exit=0") == 2, evidence
    assert evidence.count("Content Protection:") == 2, evidence
    assert "CURRENTLY_ENABLED" in success.stdout, success.stdout
    env["MOCK_HDCP_FAILURE"] = "1"
    fail = run("bash", script, env=env, check=False)
    assert fail.returncode == 2, fail.stderr + fail.stdout
    evidence = (tmp / "evidence.log").read_text()
    assert evidence.count("modetest_exit=17") == 2, evidence
    assert "UNVERIFIED" in fail.stdout, fail.stdout


def test_provenance(tmp):
    source = tmp / "product"
    hwc = tmp / "hwc"
    out = tmp / "result"
    source.mkdir()
    hwc.mkdir()
    git(source, "init", "-q")
    git(source, "checkout", "-q", "-b", "feature")
    git(hwc, "init", "-q")
    target = hwc / "source.cpp"
    target.write_text("int main() { return 0; }\n")
    git(hwc, "add", ".")
    git(hwc, "-c", "user.name=CI", "-c", "user.email=ci@example.org",
        "commit", "-q", "-m", "initial")
    target.write_text("int main() { return 1; }\n")
    patch = git(hwc, "diff")
    assert patch.startswith("diff --git")
    dirpath = source / "patches/lineage-22.1"
    dirpath.mkdir(parents=True)
    (dirpath / "drm_hwcomposer_i915_hdcp_desired.patch").write_text(patch + "\n")
    git(source, "add", ".")
    git(source, "-c", "user.name=CI", "-c", "user.email=ci@example.org",
        "commit", "-q", "-m", "patch-a")
    first_sha = git(source, "rev-parse", "HEAD")
    helper = str(ROOT / "hdcp/verify_product_patch_provenance.sh")
    good = run("bash", helper, str(source), "refs/heads/feature", str(hwc),
               str(out), check=False)
    assert good.returncode == 0, good.stderr + good.stdout
    assert good.stdout.strip() == first_sha
    assert (out / "product-pr15-verified-head.txt").read_text().strip() == first_sha

    # Simulate a new product revision with a changed patch while the HWC
    # checkout is still built from the previous version.
    (dirpath / "drm_hwcomposer_i915_hdcp_desired.patch").write_text(
        patch.replace("+int main() { return 1; }", "+int main() { return 2; }") + "\n")
    git(source, "add", ".")
    git(source, "-c", "user.name=CI", "-c", "user.email=ci@example.org",
        "commit", "-q", "-m", "patch-b")
    second_sha = git(source, "rev-parse", "HEAD")
    assert second_sha != first_sha
    stale = run("bash", helper, str(source), "refs/heads/feature", str(hwc),
                str(out), check=False)
    assert stale.returncode != 0, stale.stdout + stale.stderr
    assert "UNVERIFIED" in stale.stderr
    assert (out / "product-pr15-verified-head.txt").read_text().strip() != second_sha
    print("PASS: updated PR HEAD with a stale HWC patch is rejected")


def main():
    with tempfile.TemporaryDirectory(prefix="r86s-review-regression-") as d:
        base = Path(d)
        kms = base / "kms"
        kms.mkdir()
        test_kms(kms)
        provenance = base / "provenance"
        provenance.mkdir()
        test_provenance(provenance)
    print("PASS: mock adb evidence/classifier and product-HEAD provenance integration")


if __name__ == "__main__":
    main()
