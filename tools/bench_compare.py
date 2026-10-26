# Compares a bench run (JSON lines from `-bench:<file>`) with a saved baseline and checks counter budgets.
#   python3 -I tools/bench_compare.py build/bench/latest.jsonl [--baseline build/bench/baseline.jsonl] [--budget tests/bench/budget.json]
# Timings are only printed: they vary by machine and load. Counters (boxes, text layouts, ...) are
# deterministic for a given fixture and script, so the budget fails the run when one grows past its cap.
import json, sys

COUNTERS = ('boxes', 'keyed_boxes', 'text_layouts', 'shape_calls', 'glyphs', 'draw_cmds', 'arena_bytes')

def load(path):
    out = {}
    for line in open(path, encoding='utf-8'):
        line = line.strip()
        if line: o = json.loads(line); out[o['name']] = o  # the last run of a section wins
    return out

def main(argv):
    if len(argv) < 2:
        print(open(__file__).read().split('\nimport')[0]); return 2
    latest = load(argv[1])
    baseline, budget = {}, {}
    i = 2
    while i < len(argv):
        if argv[i] == '--baseline' and i + 1 < len(argv):
            try: baseline = load(argv[i + 1])
            except FileNotFoundError: pass
            i += 2
        elif argv[i] == '--budget' and i + 1 < len(argv):
            budget = json.load(open(argv[i + 1], encoding='utf-8')); i += 2
        else:
            print('unknown argument', argv[i]); return 2
    print('%-16s %9s %9s %7s %9s %7s %6s' % ('section', 'pass ms', 'baseline', 'speedup', 'frame ms', 'boxes', 'texts'))
    for name, o in latest.items():
        med = o['pass_ms']['median']
        b = baseline.get(name)
        base = '%9.3f' % b['pass_ms']['median'] if b else '%9s' % '-'
        speed = '%6.2fx' % (b['pass_ms']['median'] / med) if b and med > 0 else '%7s' % '-'
        print('%-16s %9.3f %s %s %9.3f %7d %6d' % (name, med, base, speed, o['frame_ms']['median'], o['boxes'], o['text_layouts']))
    fail = False
    for name, caps in budget.items():
        if name.startswith('_'): continue
        o = latest.get(name)
        if o is None:
            print('FAIL budget: section %r did not run' % name); fail = True; continue
        for k, cap in caps.items():
            if k in COUNTERS and o[k] > cap:
                print('FAIL budget: %s %s = %d, cap %d' % (name, k, o[k], cap)); fail = True
    if budget and not fail: print('budget ok')
    return 1 if fail else 0

if __name__ == '__main__':
    sys.exit(main(sys.argv))
