// Package etf is an Erlang External Term Format codec shaped for the Discord
// gateway (`encoding=etf`).
//
// Decoding produces a generic Value tree; encoding reproduces the byte layout
// of Discord's official client encoder (an erlpack port):
//   - every string is BINARY_EXT ('m'), never STRING_EXT
//   - integers: 0..255 SMALL_INTEGER, int32 INTEGER, otherwise SMALL_BIG with
//     the minimal number of little-endian digit bytes
//   - non-integral numbers: NEW_FLOAT ('F')
//   - nil/true/false: SMALL_ATOM ('s')
//   - maps: MAP_EXT with keys in insertion order
//   - lists: LIST_EXT + NIL tail; an empty list is just NIL_EXT ('j')
//
// Representation (union nil == the atom `nil` == JSON null):
//   i64 any integer that fits; Big only for magnitudes that don't
//   string BINARY_EXT; Atom for atoms other than nil/true/false
//   Charlist STRING_EXT (an Erlang list of bytes, rendered as an int array)
//
// All allocations go to the allocator passed in; use an arena per message
// and free it wholesale. `destroy` exists for non-arena use.
package etf

VERSION :: 131

Tag :: enum u8 {
	New_Float       = 70,  // 'F'
	Compressed      = 80,  // 'P'
	Small_Integer   = 97,  // 'a'
	Integer         = 98,  // 'b'
	Float           = 99,  // 'c'
	Atom            = 100, // 'd'
	Small_Tuple     = 104, // 'h'
	Large_Tuple     = 105, // 'i'
	Nil             = 106, // 'j'
	String          = 107, // 'k'
	List            = 108, // 'l'
	Binary          = 109, // 'm'
	Small_Big       = 110, // 'n'
	Large_Big       = 111, // 'o'
	Map             = 116, // 't'
	Atom_Utf8       = 118, // 'v'
	Small_Atom_Utf8 = 119, // 'w'
	Small_Atom      = 115, // 's'
}

Error :: enum {
	None,
	Truncated,
	Bad_Version,
	Bad_Tag,
	Too_Deep,
	Too_Large,
	Improper_List,
	Bad_Float,
	Zlib,
	Trailing_Data,
	Out_Of_Memory,
	Bad_Json,
}

Atom :: distinct string
Charlist :: distinct string
// Big holds integers whose magnitude doesn't fit in i64. digits is little-endian.
Big :: struct {
	negative: bool,
	digits:   []u8,
}
List :: distinct []Value
Tuple :: distinct []Value
Pair :: struct {
	key, value: Value,
}
Map :: distinct []Pair

Value :: union {
	bool,
	i64,
	f64,
	Big,
	string,
	Atom,
	Charlist,
	List,
	Tuple,
	Map,
}

// map_get finds the first value for a binary or atom key.
map_get :: proc(m: Map, key: string) -> (Value, bool) {
	for p in m {
		switch k in p.key {
		case string:
			if k == key do return p.value, true
		case Atom:
			if string(k) == key do return p.value, true
		case bool, i64, f64, Big, Charlist, List, Tuple, Map:
		}
	}
	return nil, false
}

// as_u64 reads an integer (i64 or Big up to 64 bits) as unsigned: snowflakes.
as_u64 :: proc(v: Value) -> (u64, bool) {
	#partial switch x in v {
	case i64:
		if x < 0 do return 0, false
		return u64(x), true
	case Big:
		if x.negative do return 0, false
		r: u64
		for i := len(x.digits) - 1; i >= 0; i -= 1 {
			if r >> 56 != 0 do return 0, false
			r = r << 8 | u64(x.digits[i])
		}
		return r, true
	}
	return 0, false
}

destroy :: proc(v: Value, allocator := context.allocator) {
	switch x in v {
	case bool, i64, f64:
	case Big:
		delete(x.digits, allocator)
	case string:
		delete(x, allocator)
	case Atom:
		delete(string(x), allocator)
	case Charlist:
		delete(string(x), allocator)
	case List:
		for e in x do destroy(e, allocator)
		delete(([]Value)(x), allocator)
	case Tuple:
		for e in x do destroy(e, allocator)
		delete(([]Value)(x), allocator)
	case Map:
		for p in x {
			destroy(p.key, allocator)
			destroy(p.value, allocator)
		}
		delete(([]Pair)(x), allocator)
	}
}

// big_from_u64 makes the canonical Value for an unsigned 64-bit integer.
big_from_u64 :: proc(x: u64, allocator := context.allocator) -> Value {
	if x <= u64(max(i64)) do return i64(x)
	d := make([]u8, 8, allocator)
	for i in 0 ..< 8 do d[i] = u8(x >> (8 * uint(i)))
	return Big{digits = d}
}
