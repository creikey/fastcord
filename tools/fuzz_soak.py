#!/usr/bin/env python3
"""Fuzz every target at once for a long time, from a private copy of build/fuzz, so builds can go on.

usage: python -I tools/fuzz_soak.py <minutes> [slice-seconds] [targets...]

Runs up to cores - 2 targets at a time, each for slice-seconds, round and round. Corpora grow in
build/fuzz_corpus. A failure's input goes to tests/fuzz/<target>/ and its output to
build/fuzz_soak/<input>.txt; the target then carries on. Never touches the network.
"""
import os
import shutil
import struct
import subprocess
import sys
import time

OUT = "build/fuzz_soak"


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    minutes = float(sys.argv[1])
    slice_s = sys.argv[2] if len(sys.argv) > 2 else "120"
    os.makedirs(OUT, exist_ok=True)
    exe = os.path.abspath("build/fuzz-soak.exe" if os.path.exists("build/fuzz.exe") else "build/fuzz-soak")
    shutil.copy("build/fuzz.exe" if exe.endswith(".exe") else "build/fuzz", exe)
    shutil.copy("build/fuzz.blocks", "build/fuzz-soak.blocks")
    targets = sys.argv[3:] or subprocess.run([exe, "list"], capture_output=True, text=True).stdout.split()
    workers = max(1, (os.cpu_count() or 4) - 2)
    end = time.time() + minutes * 60
    queue = list(targets)
    running = {}
    failures = 0
    while running or time.time() < end:
        while len(running) < workers and queue and time.time() < end:
            t = queue.pop(0)
            log = open(f"{OUT}/{t}.log", "wb")
            running[t] = (subprocess.Popen([exe, t, slice_s], stdout=log, stderr=subprocess.STDOUT), log)
        time.sleep(1)
        for t, (p, log) in list(running.items()):
            code = p.poll()
            if code is None:
                continue
            log.close()
            del running[t]
            queue.append(t)
            if code == 0:
                continue
            failures += 1
            stamp = int(time.time() * 1000)
            with open(f"build/fuzz_inputs/{t}.last", "rb") as f:
                n = struct.unpack("<q", f.read(8))[0]
                data = f.read(n)
            os.makedirs(f"tests/fuzz/{t}", exist_ok=True)
            with open(f"tests/fuzz/{t}/crash-{stamp}.bin", "wb") as f:
                f.write(data)
            shutil.copy(f"{OUT}/{t}.log", f"{OUT}/{t}-{stamp}.txt")
            print(f"{t}: exit {code}, crash-{stamp}.bin", flush=True)
    print(f"soak done: {failures} failures", flush=True)


main()
