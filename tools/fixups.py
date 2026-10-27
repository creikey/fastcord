# Manual fixes applied after each transpile: (file, old, new). Keeps hand edits across regenerations.
import sys, os
FIX = []
def fix(f, old, new): FIX.append((f, old, new))
NEW = {}  # whole new files: path -> content
def newfile(f, content): NEW[f] = content

fix('etf/etf.jai', 'Value :: __UNION__(bool|s64|float64|Big|string|Atom|Charlist|List|Tuple|Map);', '''// A decoded term. kind selects the field; Atom and Charlist keep their bytes in s, Tuple its items in list.
Kind :: enum u8 { Nil; Bool; Int; Float; Big; String; Atom; Charlist; List; Tuple; Map; }
Value :: struct {
	kind: Kind;
	union { b: bool; i: s64; f: float64; big: Big; s: string; list: []Value; map: []Pair; }
}
vbool :: (b: bool) -> Value { return .{kind = .Bool, b = b}; }
vint :: (i: s64) -> Value { return .{kind = .Int, i = i}; }
vfloat :: (f: float64) -> Value { return .{kind = .Float, f = f}; }
vbig :: (b: Big) -> Value { return .{kind = .Big, big = b}; }
vstring :: (s: string) -> Value { return .{kind = .String, s = s}; }
vatom :: (s: string) -> Value { return .{kind = .Atom, s = s}; }
vcharlist :: (s: string) -> Value { return .{kind = .Charlist, s = s}; }
vlist :: (l: []Value) -> Value { return .{kind = .List, list = l}; }
vtuple :: (l: []Value) -> Value { return .{kind = .Tuple, list = l}; }
vmap :: (m: []Pair) -> Value { return .{kind = .Map, map = m}; }
is_nil :: inline (v: Value) -> bool { return v.kind == .Nil; }''')

if __name__ == '__main__':
    root = sys.argv[1]
    bad = 0
    for f, old, new in FIX:
        p = os.path.join(root, f)
        s = open(p).read()
        if old not in s:
            print('FIXUP MISS', f, repr(old[:80])); bad += 1; continue
        open(p, 'w').write(s.replace(old, new, 1))
    for f, c in NEW.items():
        open(os.path.join(root, f), 'w').write(c)
    print(f'fixups: {len(FIX) - bad}/{len(FIX)} applied')
