#!/usr/bin/env python3
"""Host regression for LineageOS 22.1 TunerFilter callback/close lock cycles.

Run from the Android source root AFTER applying tools F1 patch:
    python3 vendor/maleicacid/android_device_maleicacid_androidtv_tools/tests/test_tuner_filter_callback_lock.py
Or set TUNER_FILTER_SOURCE to the patched TunerFilter.cpp path.

Compile the *actual method bodies* extracted from the patched Framework file,
not a separately reimplemented callback. Only Android types are substituted.
"""
import os
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

SOURCE = Path(os.environ.get("TUNER_FILTER_SOURCE", "frameworks/av/services/tuner/TunerFilter.cpp"))
METHODS = (
    "onFilterEvent",
    "onFilterStatus",
    "sendSharedFilterStatus",
    "attachSharedFilterCallback",
    "detachSharedFilterCallback",
    "detachCallbacks",
)

def extract_method(source, name):
    match = re.search(r"\bTunerFilter::FilterCallback::" + name + r"\s*\(", source)
    if not match:
        raise AssertionError("Missing real Framework method: " + name)
    start = source.rfind("\n", 0, match.start()) + 1
    brace = source.find("{", match.end())
    if brace < 0:
        raise AssertionError("Missing opening brace: " + name)
    depth = 0
    for position in range(brace, len(source)):
        if source[position] == "{":
            depth += 1
        elif source[position] == "}":
            depth -= 1
            if depth == 0:
                return source[start:position + 1]
    raise AssertionError("Unterminated method: " + name)

HARNESS_PREFIX = r"""
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <future>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <utility>
#include <vector>
using namespace std;
using namespace std::chrono_literals;
namespace ndk {
class ScopedAStatus {
public:
    static ScopedAStatus ok() { return {}; }
};
}
enum class DemuxFilterStatus : int { OK = 1 };
struct DemuxFilterEvent {};
struct Mutex {
    mutex m;
    struct Autolock {
        explicit Autolock(Mutex& value) : held(value.m) {}
        lock_guard<mutex> held;
    };
};
struct ITunerFilterCallback {
    virtual ~ITunerFilterCallback() = default;
    virtual void onFilterEvent(const vector<DemuxFilterEvent>&) = 0;
    virtual void onFilterStatus(DemuxFilterStatus) = 0;
};
class TunerFilter {
public:
    class FilterCallback {
    public:
        explicit FilterCallback(shared_ptr<ITunerFilterCallback> cb)
          : mTunerFilterCallback(std::move(cb)) {}
        ndk::ScopedAStatus onFilterEvent(const vector<DemuxFilterEvent>&);
        ndk::ScopedAStatus onFilterStatus(DemuxFilterStatus);
        void sendSharedFilterStatus(int);
        void attachSharedFilterCallback(const shared_ptr<ITunerFilterCallback>&);
        void detachSharedFilterCallback();
        void detachCallbacks();
    private:
        shared_ptr<ITunerFilterCallback> mTunerFilterCallback;
        shared_ptr<ITunerFilterCallback> mOriginalCallback;
        Mutex mCallbackLock;
    };
};
"""

HARNESS_SUFFIX = r"""
struct BlockingCallback : ITunerFilterCallback {
    mutex lock;
    condition_variable changed;
    bool entered = false;
    bool released = false;
    int events = 0;
    int statuses = 0;
    void block() {
        unique_lock<mutex> guard(lock);
        entered = true;
        changed.notify_all();
        changed.wait(guard, [&] { return released; });
    }
    void onFilterEvent(const vector<DemuxFilterEvent>&) override {
        ++events;
        block();
    }
    void onFilterStatus(DemuxFilterStatus) override {
        ++statuses;
        block();
    }
    bool waitEntered() {
        unique_lock<mutex> guard(lock);
        return changed.wait_for(guard, 2s, [&] { return entered; });
    }
    void unblock() {
        lock_guard<mutex> guard(lock);
        released = true;
        changed.notify_all();
    }
};
int main(int argc, char** argv) {
    if (argc != 2) return 10;
    const string mode(argv[1]);
    auto cb = make_shared<BlockingCallback>();
    TunerFilter::FilterCallback filter(cb);
    if (mode == "detached") {
        filter.detachCallbacks();
        filter.onFilterEvent({});
        filter.onFilterStatus(DemuxFilterStatus::OK);
        return cb->events == 0 && cb->statuses == 0 ? 0 : 11;
    }
    if (mode == "shared") {
        auto original = make_shared<BlockingCallback>();
        TunerFilter::FilterCallback sharedFilter(original);
        sharedFilter.attachSharedFilterCallback(cb);
        auto delivery = async(launch::async, [&] { sharedFilter.sendSharedFilterStatus(1); });
        if (!cb->waitEntered()) { cb->unblock(); delivery.wait(); return 12; }
        auto detach = async(launch::async, [&] { sharedFilter.detachSharedFilterCallback(); });
        const bool completed = detach.wait_for(500ms) == future_status::ready;
        cb->unblock();
        delivery.wait();
        detach.wait();
        original->unblock();
        sharedFilter.onFilterStatus(DemuxFilterStatus::OK);
        return completed && cb->statuses == 1 && original->statuses == 1 ? 0 : 13;
    }
    if (mode != "event" && mode != "status") return 14;
    auto delivery = async(launch::async, [&] {
        if (mode == "event") filter.onFilterEvent({});
        else filter.onFilterStatus(DemuxFilterStatus::OK);
    });
    if (!cb->waitEntered()) { cb->unblock(); delivery.wait(); return 15; }
    // Models TunerFilter::close() detaching while a Binder callback is in flight.
    auto close = async(launch::async, [&] { filter.detachCallbacks(); });
    const bool completed = close.wait_for(500ms) == future_status::ready;
    cb->unblock();
    delivery.wait();
    close.wait();
    return completed && (mode == "event" ? cb->events == 1 : cb->statuses == 1) ? 0 : 16;
}
"""

class TunerCallbackLockRegressionTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        compiler = shutil.which("c++") or shutil.which("g++") or shutil.which("clang++")
        if compiler is None:
            raise AssertionError("C++17 compiler required for callback lock regression")
        if not SOURCE.is_file():
            raise AssertionError("Missing patched frameworks/av source: " + str(SOURCE))
        actual = SOURCE.read_text(encoding="utf-8")
        methods = "\n\n".join(extract_method(actual, method) for method in METHODS)
        cls.tempdir = tempfile.TemporaryDirectory(prefix="mediatuner-lock-")
        work = Path(cls.tempdir.name)
        code = work / "callback_test.cpp"
        code.write_text(HARNESS_PREFIX + "\n" + methods + "\n" + HARNESS_SUFFIX, encoding="utf-8")
        cls.binary = work / "callback_test"
        subprocess.run([compiler, "-std=c++17", "-pthread", "-Wall", "-Wextra", "-Werror",
                        str(code), "-o", str(cls.binary)], check=True, timeout=30)

    @classmethod
    def tearDownClass(cls):
        if hasattr(cls, "tempdir"):
            cls.tempdir.cleanup()

    def assertScenario(self, name):
        result = subprocess.run([str(self.binary), name], capture_output=True,
                                text=True, timeout=10)
        self.assertEqual(0, result.returncode,
                         "scenario=" + name + " stdout=" + result.stdout +
                         " stderr=" + result.stderr)

    def test_event_callback_does_not_block_detach(self):
        self.assertScenario("event")

    def test_status_callback_does_not_block_detach(self):
        self.assertScenario("status")

    def test_shared_status_does_not_block_shared_detach(self):
        self.assertScenario("shared")

    def test_detached_callback_does_not_deliver(self):
        self.assertScenario("detached")

if __name__ == "__main__":
    unittest.main()
