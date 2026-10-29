# Lists each vendored library's pinned upstream (the `- Upstream: <git repo> <tag or commit>` line in
# vendor/<lib>/README.md), the newest release tag upstream has (or new commits, for a commit pin), and the
# OSV.dev advisories that name the pinned version. Run it before every release (README "Releasing");
# .github/workflows/vendor-check.yml runs it monthly and opens an issue when something is behind.
#   python3 -I tools/vendor_check.py     exit status 1 when a newer release is out or OSV lists the pin
import json, os, re, subprocess, sys, urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

def numbers(tag): return tuple(int(n) for n in re.findall(r'\d+', tag))

def latest_tag(repo, pin):
    # Tags shaped like the pin (v1.2.3, VER-2-13-3, version-3.54.1): no rc, alpha or other series.
    shape = re.compile('^' + re.sub(r'\d+', lambda m: r'\d+', re.escape(pin)) + '$')
    out = subprocess.run(['git', 'ls-remote', '--tags', '--refs', repo], capture_output=True, text=True, timeout=60).stdout
    tags = [l.split('refs/tags/', 1)[1] for l in out.splitlines() if 'refs/tags/' in l]
    tags = [t for t in tags if shape.match(t)]
    return max(tags, key=numbers) if tags else None

def head_commit(repo):
    out = subprocess.run(['git', 'ls-remote', repo, 'HEAD'], capture_output=True, text=True, timeout=60).stdout
    return out.split()[0] if out else None

def advisories(repo, pin, commit):
    q = {'commit': pin} if commit else {'package': {'name': repo, 'ecosystem': 'GIT'}, 'version': pin}
    req = urllib.request.Request('https://api.osv.dev/v1/query', json.dumps(q).encode(), {'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(req, timeout=30) as r: return [v['id'] for v in json.load(r).get('vulns', [])]
    except Exception as e:
        return [f'(OSV query failed: {e})']

behind = False
for lib in sorted(os.listdir(os.path.join(ROOT, 'vendor'))):
    readme = os.path.join(ROOT, 'vendor', lib, 'README.md')
    if not os.path.isfile(readme): continue
    pins = re.findall(r'^- Upstream: (\S+) (\S+)$', open(readme, encoding='utf-8').read(), re.M)
    if not pins:
        print(f'{lib}: no "- Upstream:" line'); behind = True
    for repo, pin in pins:
        commit = re.fullmatch(r'[0-9a-f]{40}', pin) is not None
        if commit:
            head = head_commit(repo)
            new = head and head != pin and f'upstream HEAD is {head[:12]}'
        else:
            tag = latest_tag(repo, pin)
            new = tag and numbers(tag) > numbers(pin) and f'{tag} is out'
        vulns = advisories(repo, pin, commit)
        note = '; '.join(x for x in [new or '', ', '.join(vulns) and 'OSV: ' + ', '.join(vulns)] if x)
        # BoringSSL stays at Chrome's revision (TLS fingerprint): its fixes come with each Chrome bump.
        if lib == 'boringssl' and not vulns: note = ''
        print(f'{lib}: {pin[:12] if commit else pin}' + (f'  ->  {note}' if note else '  (current)'))
        # A commit pin's new commits are only listed: they aren't a release to move to.
        behind = behind or bool(vulns) or (bool(new) and not commit)
sys.exit(1 if behind else 0)
