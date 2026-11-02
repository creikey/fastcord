#!/usr/bin/env python3
"""Shrink a failing fuzz input: python tools/fuzz_min.py <target> <file> [out].

Cuts spans out of the input while build/fuzz still fails with the same exit code and the same last line of
output, so what's left is what the bug needs. <file> is a crash file under tests/fuzz/, or a
build/fuzz_inputs/<target>.last (its 8-byte length is taken off). Writes <file>.min unless given [out].
"""
import os, struct, subprocess, sys

EXE = os.path.abspath("build/fuzz.exe" if os.name == "nt" else "build/fuzz")
TMP = "build/fuzz_inputs/min.tmp"


def outcome(target, data):
    with open(TMP, "wb") as f:
        f.write(data)
    try:
        r = subprocess.run([EXE, target, "one", TMP], capture_output=True, timeout=30)
    except subprocess.TimeoutExpired:
        return ("timeout", "")
    lines = [x for x in r.stdout.decode("utf8", "replace").splitlines() if x.strip()]
    # Addresses and sizes in the message vary with the input: compare its words before the first digit.
    last = lines[-1] if lines else ""
    return (r.returncode, "".join(c for c in last if not c.isdigit())[:60])


def main():
    target, path = sys.argv[1], sys.argv[2]
    out = sys.argv[3] if len(sys.argv) > 3 else path + ".min"
    data = open(path, "rb").read()
    if path.endswith(".last"):
        n = struct.unpack("<q", data[:8])[0]
        data = data[8 : 8 + n]
    want = outcome(target, data)
    print(f"{len(data)} bytes, failure {want}")
    if want[0] == 0:
        print("doesn't fail on its own: it may depend on load, or on an earlier input")
        with open(out, "wb") as f:
            f.write(data)
        return 1
    span = max(len(data) // 2, 1)
    while True:
        at = 0
        while at < len(data):
            trial = data[:at] + data[at + span :]
            if outcome(target, trial) == want:
                data = trial
            else:
                at += span
        if span == 1:
            break
        span //= 2
    with open(out, "wb") as f:
        f.write(data)
    print(f"{len(data)} bytes in {out}")
    print(data[:400])
    return 0


sys.exit(main())
