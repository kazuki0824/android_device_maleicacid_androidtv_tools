#!/usr/bin/env python3
"""Read-only modetest sample classifier. No HDCP state is inferred from commits."""
import argparse
import re
from pathlib import Path

def classify(raw):
    samples = []
    chunks = re.split(r"(?m)^== KMS sample .*?==\s*$", raw)
    if len(chunks) < 2:
        return {"status": "UNVERIFIED", "reason": "no samples", "states": []}
    for chunk in chunks[1:]:
        if "modetest_exit=" in chunk and not re.search(r"modetest_exit=0\b", chunk):
            samples.append(None)
            continue
        hits = []
        lines = chunk.splitlines()
        for i, line in enumerate(lines):
            if not re.search(r"\bContent Protection\s*:", line):
                continue
            neighborhood = "\n".join(lines[i:i+12])
            enum = re.search(r"enums:\s*([^\n]+)", neighborhood)
            val = re.search(r"(?m)^\s*value:\s*(\d+)\s*$", neighborhood)
            if not enum or not val:
                continue
            names = dict((int(n), name) for name, n in re.findall(r"(Undesired|Desired|Enabled)\s*=\s*(\d+)", enum.group(1)))
            state = names.get(int(val.group(1)))
            if state:
                hits.append(state)
        samples.append(hits[0] if len(hits) == 1 else None)
    if any(x is None for x in samples):
        return {"status": "UNVERIFIED", "reason": "unavailable/ambiguous Content Protection property or modetest failure", "states": samples}
    transitions = list(zip(samples, samples[1:]))
    enabled = "Enabled" in samples
    lost = ("Enabled", "Desired") in transitions
    restored = lost and ("Desired", "Enabled") in transitions[transitions.index(("Enabled", "Desired"))+1:]
    return {"status": "OBSERVED_ENABLED" if enabled else "NOT_ENABLED",
            "reason": "KMS properties only; HDCP version and Widevine policy still unverified",
            "states": samples, "lost": lost, "restored": restored}

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument("file", nargs="?")
    ap.add_argument("--self-test", action="store_true")
    args=ap.parse_args()
    if args.self_test:
        def sample(state, exit_code=0):
            n={"Undesired":0,"Desired":1,"Enabled":2}[state]
            return "== KMS sample 1 ==\n  14 Content Protection:\n    flags: enum\n    enums: Undesired=0 Desired=1 Enabled=2\n    value: %d\nmodetest_exit=%d\n" % (n,exit_code)
        joined="\n".join(sample(s) for s in ("Undesired","Desired","Enabled","Desired","Enabled"))
        result=classify(joined)
        assert result["status"]=="OBSERVED_ENABLED" and result["lost"] and result["restored"],result
        assert classify(sample("Desired"))["status"]=="NOT_ENABLED"
        assert classify("== KMS sample 1 ==\nfailed\nmodetest_exit=1")["status"]=="UNVERIFIED"
        assert classify("no DRM properties")["status"]=="UNVERIFIED"
        print("PASS: synthetic KMS state transitions, loss/reauth, and tool failure are classified")
        return
    if not args.file: ap.error("supply a capture file or --self-test")
    result=classify(Path(args.file).read_text(errors="replace"))
    print("KMS Content Protection: "+result["status"])
    print("States: "+repr(result["states"]))
    print("Reason: "+result["reason"])
    if "lost" in result: print("Link loss observed:",result["lost"]," Reauth observed:",result["restored"])
    if result["status"]=="UNVERIFIED": raise SystemExit(2)

if __name__=="__main__":
    main()
