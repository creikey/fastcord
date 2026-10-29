# Prints a release's notes as markdown: commit titles since the previous tag, grouped by area
# ("Area: Sentence"), leaving out the areas users don't see. release.yml runs it at the release's commit.
#   python3 -I tools/release_notes.py <new tag>
import subprocess, sys
def git(*a): return subprocess.run(['git', *a], capture_output=True, text=True).stdout.strip()
new = sys.argv[1] if len(sys.argv) > 1 else 'main'
prev = git('describe', '--tags', '--abbrev=0', 'HEAD^')
HIDDEN = {'docs', 'site', 'todo', 'tests', 'tools', 'ci', 'traffic'}
areas = {}
for s in git('log', '--no-merges', '--format=%s', f'{prev}..HEAD' if prev else 'HEAD').splitlines():
    area, sep, rest = s.partition(': ')
    if not sep or area.lower() in HIDDEN or len(area) > 30: continue
    areas.setdefault(area, []).append(rest)
out = [f'## {a}\n' + ''.join(f'- {r}\n' for r in reversed(rs)) for a, rs in sorted(areas.items(), key=lambda x: -len(x[1]))]
print('\n'.join(out) or 'Small fixes.')
if prev: print(f'\nAll changes: https://github.com/creikey/fastcord/compare/{prev}...{new}')
