// Erlang External Term Format (the gateway's `encoding=etf`) and JSON, both into one Value tree.
// Encoding is laid out exactly like the official client's encoder; decoding allocates in context.allocator.
#import "Basic";
#import "Math";
#import "String";
inflate :: #import "inflate";
#load "decode.jai";
#load "json.jai";

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
    Bad_Json;
}

Atom :: string;
Charlist :: string;
// Big holds integers whose magnitude doesn't fit in s64. digits is little-endian.
Big :: struct {
    negative: bool;
    digits: []u8;
}
List :: []Value;
Tuple :: []Value;
Pair :: struct { key, value: Value; }
Map :: []Pair;

// A term. kind selects the field; Atom and Charlist keep their bytes in s, Tuple its items in list.
Kind :: enum u8 { Nil; Bool; Int; Float; Big; String; Atom; Charlist; List; Tuple; Map; }
Value :: struct {
    kind: Kind;
    union { b: bool; i: s64; f: float64; big: Big; s: string; list: []Value; map: []Pair; }
}
vbool     :: (b: bool) -> Value     { return .{kind = .Bool, b = b}; }
vint      :: (i: s64) -> Value      { return .{kind = .Int, i = i}; }
vfloat    :: (f: float64) -> Value  { return .{kind = .Float, f = f}; }
vbig      :: (b: Big) -> Value      { return .{kind = .Big, big = b}; }
vstring   :: (s: string) -> Value   { return .{kind = .String, s = s}; }
vatom     :: (s: string) -> Value   { return .{kind = .Atom, s = s}; }
vcharlist :: (s: string) -> Value   { return .{kind = .Charlist, s = s}; }
vlist     :: (l: []Value) -> Value  { return .{kind = .List, list = l}; }
vtuple    :: (l: []Value) -> Value  { return .{kind = .Tuple, list = l}; }
vmap      :: (m: []Pair) -> Value   { return .{kind = .Map, map = m}; }
is_nil :: inline (v: Value) -> bool { return v.kind == .Nil; }

// map_get finds the first value for a binary or atom key.
map_get :: (m: Map, key: string) -> Value, bool {
    for m if (it.key.kind == .String || it.key.kind == .Atom) && it.key.s == key return it.value, true;
    return .{}, false;
}

// as_u64 reads an integer (s64 or Big up to 64 bits) as unsigned: snowflakes.
as_u64 :: (v: Value) -> u64, bool {
    if v.kind == .Int && v.i >= 0 return cast(u64) v.i, true;
    if v.kind != .Big || v.big.negative return 0, false;
    r: u64;
    for < v.big.digits {
        if r >> 56 return 0, false;
        r = (r << 8) | it;
    }
    return r, true;
}

// big_from_u64 makes the canonical Value for an unsigned 64-bit integer.
big_from_u64 :: (x: u64) -> Value {
    if x <= cast(u64) S64_MAX return vint(cast(s64) x);
    return vbig(.{digits = le_digits(x)});
}

// encode returns a complete term, version byte included.
encode :: (v: Value) -> []u8, Error {
    buf: [..]u8;
    array_reserve(*buf, 256);
    array_add(*buf, VERSION);
    err := encode_term(*buf, v, 0);
    if err != .None { array_free(buf); return .[], err; }
    return buf, .None;
}

// Map_Builder collects a payload's pairs in insertion order, in the allocator current at map_builder.
Map_Builder :: struct { pairs: [..]Pair; }
map_builder :: (cap := 8) -> Map_Builder {
    b: Map_Builder;
    array_reserve(*b.pairs, cap);
    return b;
}
map_put :: (b: *Map_Builder, key: string, value: Value) { array_add(*b.pairs, .{vstring(key), value}); }
map_done :: (b: *Map_Builder) -> Map { return b.pairs; }

#scope_module

VERSION :: 131;

Tag :: enum u8 {
    New_Float       :: 70;   // 'F'
    Compressed      :: 80;   // 'P'
    Small_Integer   :: 97;   // 'a'
    Integer         :: 98;   // 'b'
    Float           :: 99;   // 'c'
    Atom            :: 100;  // 'd'
    Small_Tuple     :: 104;  // 'h'
    Large_Tuple     :: 105;  // 'i'
    Nil             :: 106;  // 'j'
    String          :: 107;  // 'k'
    List            :: 108;  // 'l'
    Binary          :: 109;  // 'm'
    Small_Big       :: 110;  // 'n'
    Large_Big       :: 111;  // 'o'
    Small_Atom      :: 115;  // 's'
    Map             :: 116;  // 't'
    Atom_Utf8       :: 118;  // 'v'
    Small_Atom_Utf8 :: 119;  // 'w'
}

// Discord nests about ten deep. A debug build spends about 2.7 KiB of stack per level (release about
// 0.5 KiB), so this must stay well under 1 MiB / 2.7 KiB, the default thread stack.
MAX_DEPTH :: 128;
MAX_INFLATED :: 64 << 20;  // cap for compressed terms (tag 80)

le_digits :: (x: u64) -> []u8 {
    d := NewArray(8, u8, false);
    for * d it.* = cast(u8) (x >> (8 * it_index));
    return d;
}

put_tag :: (buf: *[..]u8, t: Tag) { array_add(buf, cast(u8) t); }
put_u16 :: (buf: *[..]u8, x: int) { array_add(buf, cast(u8) (x >> 8), cast(u8) x); }
put_u32 :: (buf: *[..]u8, x: u32) { array_add(buf, cast(u8) (x >> 24), cast(u8) (x >> 16), cast(u8) (x >> 8), cast(u8) x); }
put_bytes :: (buf: *[..]u8, s: string) { array_add(buf, ..cast([]u8) s); }

put_atom :: (buf: *[..]u8, name: string) {
    if name.count < 256 {
        array_add(buf, cast(u8) Tag.Small_Atom, cast(u8) name.count);
    } else {
        put_tag(buf, .Atom);
        put_u16(buf, name.count);
    }
    put_bytes(buf, name);
}

put_int :: (buf: *[..]u8, x: s64) {
    if x >= 0 && x <= 255 {
        array_add(buf, cast(u8) Tag.Small_Integer, cast(u8) x);
    } else if x >= S32_MIN && x <= S32_MAX {
        put_tag(buf, .Integer);
        put_u32(buf, cast,no_check(u32) x);
    } else {
        mag := ifx x < 0 then 0 - cast,no_check(u64) x else cast(u64) x;
        n: u8;
        t := mag;
        while t { n += 1; t >>= 8; }
        array_add(buf, cast(u8) Tag.Small_Big, n, cast(u8) (x < 0));
        for 0..n-1 array_add(buf, cast(u8) (mag >> (8 * it)));
    }
}

encode_term :: (buf: *[..]u8, v: Value, depth: int) -> Error {
    if depth > MAX_DEPTH return .Too_Deep;
    if v.kind == {
      case .Nil;   put_atom(buf, "nil");
      case .Bool;  put_atom(buf, ifx v.b then "true" else "false");
      case .Int;   put_int(buf, v.i);
      case .Float;
        bits := (cast(*u64) *v.f).*;
        put_tag(buf, .New_Float);
        put_u32(buf, cast(u32) (bits >> 32));
        put_u32(buf, cast(u32) bits);
      case .Big;
        n := v.big.digits.count;
        if n < 256 {
            array_add(buf, cast(u8) Tag.Small_Big, cast(u8) n);
        } else {
            put_tag(buf, .Large_Big);
            put_u32(buf, cast(u32) n);
        }
        array_add(buf, cast(u8) v.big.negative);
        array_add(buf, ..v.big.digits);
      case .String;
        if v.s.count > U32_MAX return .Too_Large;
        put_tag(buf, .Binary);
        put_u32(buf, cast(u32) v.s.count);
        put_bytes(buf, v.s);
      case .Atom;
        if v.s.count > 65535 return .Too_Large;
        put_atom(buf, v.s);
      case .Charlist;
        if v.s.count <= 65535 {
            put_tag(buf, .String);
            put_u16(buf, v.s.count);
            put_bytes(buf, v.s);
        } else {
            put_tag(buf, .List);
            put_u32(buf, cast(u32) v.s.count);
            for cast([]u8) v.s array_add(buf, cast(u8) Tag.Small_Integer, it);
            put_tag(buf, .Nil);
        }
      case .List;
        if !v.list.count { put_tag(buf, .Nil); return .None; }
        put_tag(buf, .List);
        put_u32(buf, cast(u32) v.list.count);
        for v.list { err := encode_term(buf, it, depth + 1); if err return err; }
        put_tag(buf, .Nil);
      case .Tuple;
        if v.list.count < 256 {
            array_add(buf, cast(u8) Tag.Small_Tuple, cast(u8) v.list.count);
        } else {
            put_tag(buf, .Large_Tuple);
            put_u32(buf, cast(u32) v.list.count);
        }
        for v.list { err := encode_term(buf, it, depth + 1); if err return err; }
      case .Map;
        put_tag(buf, .Map);
        put_u32(buf, cast(u32) v.map.count);
        for v.map {
            err := encode_term(buf, it.key, depth + 1);
            if err return err;
            err = encode_term(buf, it.value, depth + 1);
            if err return err;
        }
    }
    return .None;
}
