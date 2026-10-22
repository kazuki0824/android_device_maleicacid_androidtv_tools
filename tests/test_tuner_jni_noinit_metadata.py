#!/usr/bin/env python3
"""Regression for the real patched LineageOS 22.1 tuner JNI metadata switch.

Run from the Android source root after tools apply_patches.sh. An absent
framework source fails the test rather than silently skipping verification.
"""
import os
import re
import unittest
from pathlib import Path

SOURCE = Path(os.environ.get("TUNER_JNI_SOURCE", "frameworks/base/media/jni/android_media_tv_Tuner.cpp"))
CASE_RE = re.compile(r"(?m)^\s*(case\s+DemuxFilterMediaEventExtraMetaData::Tag::(\w+)|default)\s*:")


def get_metadata_cases(source: str) -> dict[str, str]:
    function = "void FilterClientCallbackImpl::getMediaEvent("
    method = source.find(function)
    if method < 0:
        raise AssertionError("Missing real Framework getMediaEvent method")
    match = re.search(r"switch\s*\(mediaEvent\.extraMetaData\.getTag\(\)\)\s*\{", source[method:])
    if match is None:
        raise AssertionError("Missing metadata switch in real getMediaEvent")
    start = method + match.end()
    depth = 1
    end = start
    while end < len(source) and depth:
        if source[end] == "{":
            depth += 1
        elif source[end] == "}":
            depth -= 1
        end += 1
    if depth:
        raise AssertionError("Unbalanced metadata switch")
    body = source[start : end - 1]
    branches = list(CASE_RE.finditer(body))
    return {
        m.group(2) or "default": body[m.end() : branches[i + 1].start() if i + 1 < len(branches) else len(body)]
        for i, m in enumerate(branches)
    }


class TunerJniNoinitMetadataTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.cases = get_metadata_cases(SOURCE.read_text(encoding="utf-8"))

    def test_noinit_is_explicitly_handled_without_error(self) -> None:
        self.assertEqual("break;", self.cases["noinit"].strip())

    def test_real_audio_metadata_remains_supported(self) -> None:
        self.assertIn("audioDescriptor.reset", self.cases["audio"])
        self.assertIn("JAudioPresentationInfo::addPresentations", self.cases["audioPresentations"])

    def test_unknown_tags_still_report_an_error(self) -> None:
        self.assertIn('ALOGE("FilterClientCallbackImpl::getMediaEvent: unknown extraMetaData")', self.cases["default"])


if __name__ == "__main__":
    unittest.main()
