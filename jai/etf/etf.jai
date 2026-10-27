VERSION :: 131;

Tag :: enum u8 {
	New_Float :: 70;  // 'F'
	Compressed :: 80;  // 'P'
	Small_Integer :: 97;  // 'a'
	Integer :: 98;  // 'b'
	Float :: 99;  // 'c'
	Atom :: 100; // 'd'
	Small_Tuple :: 104; // 'h'
	Large_Tuple :: 105; // 'i'
	Nil :: 106; // 'j'
	String :: 107; // 'k'
	List :: 108; // 'l'
	Binary :: 109; // 'm'
	Small_Big :: 110; // 'n'
	Large_Big :: 111; // 'o'
	Map :: 116; // 't'
	Atom_Utf8 :: 118; // 'v'
	Small_Atom_Utf8 :: 119; // 'w'
	Small_Atom :: 115; // 's'
}

Error :: enum {
	None;
	Truncated;
	Bad_Version;
	Bad_Tag;
	Too_Deep;
	Too_Large;
	Improper_List;
	Bad_Float;
	Zlib;
	Trailing_Data;
	Out_Of_Memory;
	Bad_Json;
}

Atom :: string;
Charlist :: string;
// Big holds integers whose magnitude doesn't fit in i64. digits is little-endian.
Big :: struct {
	negative: bool;
	digits: []u8;
}
List :: []Value;
Tuple :: []Value;
Pair :: struct {
	key, value: Value;
}
Map :: []Pair;

// A decoded term. kind selects the field; Atom and Charlist keep their bytes in s, Tuple its items in list.
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
is_nil :: inline (v: Value) -> bool { return v.kind == .Nil; }

// map_get finds the first value for a binary or atom key.
map_get :: (m: Map, key: string) -> Value, bool {
	for p: m {
		if p.key.kind == {
		case .String; k := p.key.s;
			if k == key { return p.value, true; }
		case .Atom; k := p.key.s;
			if as_string(k) == key { return p.value, true; }
		case .Bool; #through; case .Int; #through; case .Float; #through; case .Big; #through; case .Charlist; #through; case .List; #through; case .Tuple; #through; case .Map; k := p.key;
		}
	}
	return .{}, false;
}

// as_u64 reads an integer (i64 or Big up to 64 bits) as unsigned: snowflakes.
as_u64 :: (v: Value) -> u64, bool {
	if v.kind == {
	case .Int; x := v.i;
		if x < 0 { return 0, false; }
		return cast(u64)(x), true;
	case .Big; x := v.big;
		if x.negative { return 0, false; }
		r: u64;
		for < i: len(x.digits) - 1..0 {
			if r >> 56 != 0 { return 0, false; }
			r = r << 8 | cast(u64)(x.digits[i]);
		}
		return r, true;
	}
	return 0, false;
}

destroy :: (v: Value, allocator := context.allocator) {
	if v.kind == {
	case .Bool; #through; case .Int; #through; case .Float; x := v;
	case .Big; x := v.big;
		delete(x.digits, allocator);
	case .String; x := v.s;
		delete(x, allocator);
	case .Atom; x := v.s;
		delete(as_string(x), allocator);
	case .Charlist; x := v.s;
		delete(as_string(x), allocator);
	case .List; x := v.list;
		for e: x { destroy(e, allocator); }
		delete(cast([]Value)(x), allocator);
	case .Tuple; x := v.list;
		for e: x { destroy(e, allocator); }
		delete(cast([]Value)(x), allocator);
	case .Map; x := v.map;
		for p: x {
			destroy(p.key, allocator);
			destroy(p.value, allocator);
		}
		delete(cast([]Pair)(x), allocator);
	}
}

// big_from_u64 makes the canonical Value for an unsigned 64-bit integer.
big_from_u64 :: (x: u64, allocator := context.allocator) -> Value {
	if x <= cast(u64)(S64_MAX) { return vint(x); }
	d := make_slice(u8, 8, allocator);
	for i: 0..7 { d[i] = cast(u8)(x >> (8 * cast(u64)(i))); }
	return vbig(Big.{digits = d});
}

