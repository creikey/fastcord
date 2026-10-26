# Fails if any tracked or untracked (non-ignored) file contains a test-account secret.
# Needles: values from discord_credentials.txt and tokens seen in .secrets/raw.
# Run before committing: python3 -I tools/check_secrets.py
import os, re, subprocess, sys
root = subprocess.run(['git', 'rev-parse', '--show-toplevel'], capture_output=True, text=True).stdout.strip()
os.chdir(root)
needles = set()
if os.path.exists('discord_credentials.txt'):
    needles |= {v for v in re.findall(r':\s*(\S+)', open('discord_credentials.txt').read()) if len(v) >= 6}
tok = re.compile(rb'(?:"token"|"[Aa]uthorization")\s*:\s*"([A-Za-z0-9_\-]{20,}\.[A-Za-z0-9_\-]{4,}\.[A-Za-z0-9_\-]{20,})"')
raw = '.secrets/raw'
if os.path.isdir(raw):
    for f in os.listdir(raw):
        p = os.path.join(raw, f)
        if not os.path.isfile(p): continue
        with open(p, 'rb') as fh:
            for i, line in enumerate(fh):
                for m in tok.finditer(line):
                    needles.add(m.group(1).decode())
                if i > 20000: break
files = subprocess.run(['git', 'ls-files', '-c', '-o', '--exclude-standard'], capture_output=True, text=True).stdout.split()
bad = []
for f in files:
    try: d = open(f, 'rb').read()
    except OSError: continue
    for n in needles:
        if n.encode() in d:
            bad.append(f)
            break
if bad:
    print('SECRET FOUND in:', *bad, sep='\n  ')
    sys.exit(1)
print(f'ok: {len(files)} files, {len(needles)} needles')
