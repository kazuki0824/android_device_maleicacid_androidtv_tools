#!/usr/bin/env python3
"""Exercise the real build driver from separate tools/build directories.

Only plain-text mocks are used. This does not compile Android or inspect ELF.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

TOOLS_HDCP = Path(__file__).resolve().parent
DRIVER = TOOLS_HDCP / "verify_android15_r86s_build.sh"


def write_executable(path, content):
    path.write_text(content)
    path.chmod(0o755)


def main():
    with tempfile.TemporaryDirectory(prefix="r86s-build-driver-path-") as temp:
        root = Path(temp)
        tools = root / "tools"
        tools_hdcp = tools / "hdcp"
        android = root / "android-build"
        bin_dir = root / "bin"
        tools_hdcp.mkdir(parents=True)
        bin_dir.mkdir()
        (android / ".repo").mkdir(parents=True)
        shutil.copyfile(DRIVER, tools_hdcp / DRIVER.name)
        write_executable(tools_hdcp / "verify_product_patch_provenance.sh",
            '#!/usr/bin/env bash\n'
            '[[ "$#" == 4 ]] || exit 9\n'
            '[[ "$3" == "$MOCK_ANDROID_ROOT/external/drm_hwcomposer" ]] || exit 10\n'
            'mkdir -p "$4"\n'
            'echo helper-found > "$4/helper-found.txt"\n'
            'echo mock-product-revision\n')
        envsetup = android / "build/envsetup.sh"
        envsetup.parent.mkdir()
        envsetup.write_text(
            'breakfast() { echo breakfast-stub; }\n'
            'm() { echo m-stub "$@"; }\n')
        widevine = android / "vendor/google/proprietary/widevine-prebuilt"
        widevine.mkdir(parents=True)
        for name in ("android.hardware.drm-service.widevine", "libwvaidl.so"):
            (widevine / name).write_text("dummy non-ELF fixture\n")
        drm = android / "external/drm_hwcomposer/drm/DrmAtomicStateManager.cpp"
        drm.parent.mkdir(parents=True)
        drm.write_text(
            'drmModeAtomicDuplicate(pset.get())\n'
            '"Content Protection"\n"Desired"\nHDCP Enabled\n')
        write_executable(bin_dir / "git", String_git)
        write_executable(bin_dir / "repo", String_repo)
        env = dict(os.environ,
                   PATH=str(bin_dir) + os.pathsep + os.environ["PATH"],
                   MOCK_ANDROID_ROOT=str(android))
        result = subprocess.run(
            ["bash", "hdcp/verify_android15_r86s_build.sh", str(android)],
            cwd=tools, env=env, capture_output=True, text=True)
        assert result.returncode == 0, result.stdout + "\n" + result.stderr
        evidence = android / "out/hdcp-validation"
        assert (evidence / "helper-found.txt").read_text().strip() == "helper-found"
        report = (evidence / "validation-provenance.txt").read_text()
        assert "Production tools PR #15 patch revision (verified): mock-product-revision" in report
        assert (evidence / "04-vintf.log").exists()
        print("PASS: relative tools script resolves sibling helper after cd to separate Android build tree")


String_git = r'''#!/usr/bin/env bash
case "$*" in
  *"rev-parse --is-inside-work-tree"*) echo true;;
  *"rev-parse HEAD"*)
    if [[ "$*" == *"device/maleicacid/virtio_x86_64_tv_grub"* ]]; then
      echo 2b152fd5242075b9ca7730b2256eb7eb5aff1554
    else
      echo 1111111111111111111111111111111111111111
    fi;;
  *"diff --"*) :;;
  *) echo "unexpected git stub: $*" >&2; exit 99;;
esac
'''
String_repo = r'''#!/usr/bin/env bash
if [[ "$1" == "manifest" ]]; then
  while (($#)); do
    if [[ "$1" == "-o" ]]; then shift; echo "<manifest/>" > "$1"; exit 0; fi
    shift
  done
fi
exit 99
'''


if __name__ == "__main__":
    main()
