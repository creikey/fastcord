# Compares a bench run (JSON lines from `-bench:<file>`) with a saved baseline and checks counter budgets.
#   python3 -I tools/bench_compare.py build/bench/latest.jsonl [--baseline build/bench/baseline.jsonl] [--budget tests/bench/budget.json]
# Timings are only printed: they vary by machine and load. Counters (boxes, text layouts, ...) are
# deterministic for a given fixture and script, so the budget fails the run when one grows past its cap.
# The one exception is startup (startup.txt): its caps sit far above any machine's times, so only a big
# regression on the path to the first frame (fonts, settings, keys, the database) fails it.
import json, sys

COUNTERS = ('boxes', 'keyed_boxes', 'text_layouts', 'shape_calls', 'glyphs', 'draw_cmds', 'arena_bytes', 'instances', 'batches')
STARTUP = ('ready_ms', 'first_frame_ms', 'drawn_ms', 'idle_rss_mb')

def load(path):
    out = {}
    for line in open(path, encoding='utf-8'):
        line = line.strip()
        if not line: continue
        o = json.loads(line)
        if 'name' in o: out[o['name']] = o  # the last run of a section wins
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
    # Latency (frame start until the GPU finished it) is the headline: the app sleeps until input, so
    # that is what a user waits for. The UI pass and render columns say where it went.
    def ms(o, k): return o.get(k, {}).get('median', 0.0)
    def speedup(b, o, k): return '%6.2fx' % (ms(b, k) / ms(o, k)) if b and ms(b, k) > 0 and ms(o, k) > 0 else '%7s' % '-'
    print('%-16s %10s %9s %7s %8s %7s %9s %7s %8s %6s %6s %6s' % ('section', 'latency ms', 'baseline', 'speedup', 'ui pass', 'speedup',
          'render ms', 'speedup', 'gpu ms', 'boxes', 'texts', 'draws'))
    for name, o in latest.items():
        if name == 'startup': continue
        b = baseline.get(name)
        base = '%9.3f' % ms(b, 'latency_ms') if b else '%9s' % '-'
        print('%-16s %10.3f %s %s %8.3f %s %9.3f %s %8.3f %6d %6d %6d' % (name, ms(o, 'latency_ms'), base, speedup(b, o, 'latency_ms'),
              ms(o, 'pass_ms'), speedup(b, o, 'pass_ms'), ms(o, 'render_ms'), speedup(b, o, 'render_ms'), ms(o, 'gpu_ms'),
              o['boxes'], o['text_layouts'], o.get('batches', 0)))
    if 'startup' in latest:
        o, b = latest['startup'], baseline.get('startup', {})
        print('startup: ' + ', '.join('%s %s%s' % (k, o[k], ' (baseline %s)' % b[k] if k in b else '') for k in STARTUP))
    fail = False
    for name, caps in budget.items():
        if name.startswith('_'): continue
        o = latest.get(name)
        if o is None:
            print('FAIL budget: section %r did not run' % name); fail = True; continue
        for k, cap in caps.items():
            if (k in COUNTERS or k in STARTUP) and o[k] > cap:
                print('FAIL budget: %s %s = %d, cap %d' % (name, k, o[k], cap)); fail = True
    if budget and not fail: print('budget ok')
    return 1 if fail else 0

if __name__ == '__main__':
    sys.exit(main(sys.argv))
