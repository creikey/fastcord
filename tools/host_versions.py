#!/usr/bin/env python3
"""Rebuild site/hosts.json: the Electron and Chrome of each desktop host version Discord's updater serves.

fastcord learns its install's host version and native build from the updater's manifest at each launch
(src/discord/startup.jai `host_manifest_loaded`), but the manifest doesn't say which Electron and Chrome a
host ships. This reads them from the host packages themselves: run daily by .github/workflows/host-versions.yml.

The updater stages rollouts per install_id, so several random ids are asked per platform to see every live
version. A new version's full package (~100-170 MB, brotli'd tar) is downloaded once and its Electron binary
searched for "Electron/x.y.z" and "Chrome/a.b.c.d".

Usage: python3 -I tools/host_versions.py [site/hosts.json]   (needs the brotli module)
"""
import io, json, sys, tarfile, urllib.request, uuid

import brotli

PLATFORMS = {"osx": "arm64", "win": "x64", "linux": "x64"}
PROBES = 12  # random install ids per platform
KEEP = 32  # versions kept per platform
MANIFEST = "https://updates.discord.com/distributions/app/manifests/latest?channel=stable&platform={}&arch={}&install_id={}"


def get(url, limit):
    # Python's default User-Agent is refused (403).
    req = urllib.request.Request(url, headers={"User-Agent": "fastcord-host-versions (github.com/creikey/fastcord)"})
    with urllib.request.urlopen(req, timeout=120) as r:
        data = r.read(limit + 1)
    if len(data) > limit:
        raise ValueError("too large: " + url)
    return data


def version_after(data, prefix, parts):
    """The dotted number after prefix (b"Electron/"), most common occurrence; no regex (untrusted input)."""
    counts = {}
    i = data.find(prefix)
    while i >= 0:
        j = i + len(prefix)
        k = j
        while k < len(data) and k - j < 32 and (48 <= data[k] <= 57 or data[k] == 46):
            k += 1
        v = data[j:k].decode()
        p = v.split(".")
        if len(p) == parts and all(x and len(x) <= 6 for x in p):
            counts[v] = counts.get(v, 0) + 1
        i = data.find(prefix, k)
    return max(counts, key=counts.get) if counts else None


def host_build(url):
    raw = brotli.decompress(get(url, 400 << 20))
    electron = chrome = None
    with tarfile.open(fileobj=io.BytesIO(raw)) as tar:
        for m in tar:
            # The Electron binary: Discord / Discord.exe, or the macOS framework's.
            name = m.name.rsplit("/", 1)[-1]
            if not m.isfile() or name not in ("Discord", "Discord.exe", "Electron Framework"):
                continue
            data = tar.extractfile(m).read()
            electron = electron or version_after(data, b"Electron/", 3)
            chrome = chrome or version_after(data, b"Chrome/", 4)
    if not electron or not chrome:
        raise ValueError("no Electron/Chrome version in " + url)
    return {"electron": electron, "chrome": chrome}


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "site/hosts.json"
    try:
        hosts = json.load(open(path))
    except FileNotFoundError:
        hosts = {}
    for platform, arch in PLATFORMS.items():
        known = hosts.setdefault(platform, {})
        offered = {}
        for _ in range(PROBES):
            m = json.loads(get(MANIFEST.format(platform, arch, uuid.uuid4()), 1 << 20))
            v = ".".join(str(int(x)) for x in m["full"]["host_version"])
            offered[v] = m["full"]["url"]
        for v, url in sorted(offered.items()):
            if v not in known:
                known[v] = host_build(url)
                print(platform, v, known[v])
        order = sorted(known, key=lambda v: [int(x) for x in v.split(".")])
        hosts[platform] = {v: known[v] for v in order[-KEEP:]}
    with open(path, "w") as f:
        json.dump(hosts, f, indent=1, sort_keys=False)
        f.write("\n")


if __name__ == "__main__":
    main()
