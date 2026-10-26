# Queries folded stacks ("outer;...;inner count" lines, as written by `-prof:<prefix>`).
#   python3 -I tools/folded.py build/bench/dm.folded top [n]              hottest procedures by self time
#   python3 -I tools/folded.py build/bench/dm.folded callers <regex> [depth]   who calls the matches (self+callees time)
#   python3 -I tools/folded.py build/bench/dm.folded callees <regex> [depth]   what the matches spend time in
# Procedure names are matched with re.search; percentages are of all samples.
import re, sys
from collections import Counter

def load(path):
    stacks = []
    for line in open(path, encoding='utf-8', errors='replace'):
        line = line.rstrip('\n')
        if not line: continue
        frames, _, n = line.rpartition(' ')
        stacks.append((frames.split(';'), int(n)))
    return stacks

def short(name):
    # ui::[core.odin]::box_make_key -> ui::box_make_key
    return re.sub(r'::\[[^\]]*\]', '', name)

def main():
    if len(sys.argv) < 3:
        print(__doc__ or open(__file__).read().split('\nimport')[0]); return 2
    stacks = load(sys.argv[1])
    total = sum(n for _, n in stacks) or 1
    cmd = sys.argv[2]
    if cmd == 'top':
        top = int(sys.argv[3]) if len(sys.argv) > 3 else 30
        self_, incl = Counter(), Counter()
        for fr, n in stacks:
            self_[fr[-1]] += n
            for f in set(fr): incl[f] += n
        print('  self%   incl%  procedure')
        for f, n in self_.most_common(top):
            print('  %5.1f   %5.1f  %s' % (100 * n / total, 100 * incl[f] / total, short(f)))
        return 0
    if cmd in ('callers', 'callees'):
        pat = re.compile(sys.argv[3])
        depth = int(sys.argv[4]) if len(sys.argv) > 4 else 4
        paths = Counter()
        hit = 0
        for fr, n in stacks:
            idx = [i for i, f in enumerate(fr) if pat.search(f) or pat.search(short(f))]
            if not idx: continue
            hit += n
            if cmd == 'callers':
                i = idx[-1]  # innermost match
                path = fr[max(0, i - depth):i + 1]
            else:
                i = idx[0]  # outermost match
                path = fr[i:i + depth + 1]
            paths[' <- '.join(short(f) for f in reversed(path)) if cmd == 'callers' else ' -> '.join(short(f) for f in path)] += n
        print('%.1f%% of samples match %r' % (100 * hit / total, sys.argv[3]))
        for p, n in paths.most_common(40):
            print('  %5.1f  %s' % (100 * n / total, p))
        return 0
    print('unknown command', cmd); return 2

if __name__ == '__main__':
    sys.exit(main())
