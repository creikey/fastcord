#!/usr/bin/env python3
"""What the fuzzer has reached, from build/fuzz.blocks and build/fuzz_cov/*.bin.

usage: python -I tools/fuzz_report.py [--blocks] [path-prefix]

One line per source file, least covered last. With a prefix, only those files; --blocks then lists
each unreached procedure with its unreached block count, which is where to aim the next generator.
"""
import collections
import glob
import sys


def main():
    args = sys.argv[1:]
    blocks = "--blocks" in args
    args = [a for a in args if a != "--blocks"]
    prefix = args[0] if args else ""
    with open("build/fuzz.blocks", encoding="utf-8") as f:
        lines = [line.rstrip("\n") for line in f]
    seen = bytearray(len(lines))
    for path in glob.glob("build/fuzz_cov/*.bin"):
        with open(path, "rb") as f:
            data = f.read()
        if len(data) != len(lines):
            print(f"skipping {path}: from another build", file=sys.stderr)
            continue
        for i, b in enumerate(data):
            if b:
                seen[i] = 1
    files = collections.Counter()
    hit = collections.Counter()
    procs = collections.Counter()
    for i, line in enumerate(lines):
        place, _, proc = line.partition(" ")
        path = place.rsplit(":", 1)[0]
        if not path.startswith(prefix):
            continue
        files[path] += 1
        if seen[i]:
            hit[path] += 1
        else:
            procs[(path, proc)] += 1
    total, reached = sum(files.values()), sum(hit.values())
    if not total:
        print("nothing matches")
        return
    print(f"{reached} of {total} blocks reached, {reached * 100 // total}%")
    for path, n in sorted(files.items(), key=lambda kv: -hit[kv[0]] / kv[1]):
        print(f"{hit[path] * 100 // n:4}% {hit[path]:6} of {n:6}  {path}")
    if blocks:
        print("\nunreached, largest first:")
        for (path, proc), n in procs.most_common(200):
            print(f"{n:6}  {path}  {proc}")


main()
