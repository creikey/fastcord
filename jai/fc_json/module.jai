// JSON values (objects as hash maps), a parser, and reflection-based marshal / unmarshal of structs.
#import "Basic";
#import "fc";
strings :: #import "fc_strings";
strconv :: #import "fc_strconv";
fmt :: #import "fc_fmt";

Kind :: enum u8 { Nil; Bool; Int; Float; String; List; Map; }
Value :: struct {
    kind: Kind;
    union { b: bool; i: s64; f: float64; s: string; list: [..]Value; map: Map(string, Value); }
}
Object :: Map(string, Value);
Array :: [..]Value;
Error :: enum { None; Invalid; Eof; }
Specification :: enum { JSON; JSON5; SJSON; }

parse :: (data: []u8, spec := Specification.JSON, parse_integers := false, allocator := context.allocator) -> Value, Error {
    push_allocator(allocator);
    p := Parser.{s = as_string(data), ints = parse_integers};
    v, ok := value(*p);
    if !ok return .{}, .Invalid;
    return v, .None;
}
parse :: (s: string, spec := Specification.JSON, parse_integers := false, allocator := context.allocator) -> Value, Error {
    v, e := parse(to_bytes(s), spec, parse_integers, allocator);
    return v, e;
}
parse_string :: (s: string, spec := Specification.JSON, parse_integers := false, allocator := context.allocator) -> Value, Error {
    v, e := parse(to_bytes(s), spec, parse_integers, allocator);
    return v, e;
}

// marshal / unmarshal walk the type info: structs are objects (field order), arrays arrays,
// Map(string, T) objects (sorted by key), enums their names.
Marshal_Options :: struct { pretty: bool; sort_maps_by_key: bool; }
marshal :: (v: Any, opts := Marshal_Options.{}, allocator := context.allocator) -> []u8, Error {
    b := strings.builder_make(allocator);
    write(*b, v, opts, 0);
    return b.buf, .None;
}
unmarshal :: (data: []u8, out: *$T, allocator := context.allocator) -> *void {
    v, err := parse(data, allocator = temp);
    if err != .None return cast(*void) 1;
    push_allocator(allocator);
    read(v, type_info(T), out);
    return null;
}

#scope_file
Parser :: struct { s: string; i: int; ints: bool; }
ws :: (p: *Parser) { while p.i < p.s.count && (p.s[p.i] == #char " " || p.s[p.i] == #char "\t" || p.s[p.i] == #char "\n" || p.s[p.i] == #char "\r") p.i += 1; }
lit :: (p: *Parser, w: string) -> bool {
    if !strings.has_prefix(sub_from(p.s, p.i), w) return false;
    p.i += w.count;
    return true;
}
value :: (p: *Parser) -> Value, bool {
    ws(p);
    if p.i >= p.s.count return .{}, false;
    c := p.s[p.i];
    if c == #char "{" {
        p.i += 1;
        v := Value.{kind = .Map};
        ws(p);
        if p.i < p.s.count && p.s[p.i] == #char "}" { p.i += 1; return v, true; }
        while true {
            ws(p);
            k, ok := str(p); if !ok return .{}, false;
            ws(p);
            if p.i >= p.s.count || p.s[p.i] != #char ":" return .{}, false;
            p.i += 1;
            x, ok2 := value(p); if !ok2 return .{}, false;
            at(*v.map, k).* = x;
            ws(p);
            if p.i < p.s.count && p.s[p.i] == #char "," { p.i += 1; continue; }
            if p.i < p.s.count && p.s[p.i] == #char "}" { p.i += 1; return v, true; }
            return .{}, false;
        }
    }
    if c == #char "[" {
        p.i += 1;
        v := Value.{kind = .List};
        ws(p);
        if p.i < p.s.count && p.s[p.i] == #char "]" { p.i += 1; return v, true; }
        while true {
            x, ok := value(p); if !ok return .{}, false;
            array_add(*v.list, x);
            ws(p);
            if p.i < p.s.count && p.s[p.i] == #char "," { p.i += 1; continue; }
            if p.i < p.s.count && p.s[p.i] == #char "]" { p.i += 1; return v, true; }
            return .{}, false;
        }
    }
    if c == #char "\"" { s, ok := str(p); return .{kind = .String, s = s}, ok; }
    if lit(p, "true") return .{kind = .Bool, b = true}, true;
    if lit(p, "false") return .{kind = .Bool, b = false}, true;
    if lit(p, "null") return .{}, true;
    start := p.i;
    is_float := false;
    while p.i < p.s.count {
        d := p.s[p.i];
        if d == #char "." || d == #char "e" || d == #char "E" is_float = true;
        else if !(d == #char "-" || d == #char "+" || (d >= #char "0" && d <= #char "9")) break;
        p.i += 1;
    }
    t := sub(p.s, start, p.i);
    if !t.count return .{}, false;
    if p.ints && !is_float { n, ok := strconv.parse_i64(t); return .{kind = .Int, i = n}, ok; }
    f, ok := strconv.parse_f64(t);
    return .{kind = .Float, f = f}, ok;
}
str :: (p: *Parser) -> string, bool {
    if p.i >= p.s.count || p.s[p.i] != #char "\"" return "", false;
    p.i += 1;
    b: [..]u8;
    while p.i < p.s.count {
        c := p.s[p.i];
        p.i += 1;
        if c == #char "\"" return as_string(b), true;
        if c != #char "\\" { array_add(*b, c); continue; }
        if p.i >= p.s.count return "", false;
        e := p.s[p.i];
        p.i += 1;
        if e == {
            case #char "n"; array_add(*b, #char "\n");
            case #char "t"; array_add(*b, #char "\t");
            case #char "r"; array_add(*b, #char "\r");
            case #char "b"; array_add(*b, 8);
            case #char "f"; array_add(*b, 12);
            case #char "u";
                r, ok := hex4(p); if !ok return "", false;
                if r >= 0xD800 && r < 0xDC00 && p.i + 6 <= p.s.count && p.s[p.i] == #char "\\" && p.s[p.i+1] == #char "u" {
                    p.i += 2;
                    lo, ok2 := hex4(p); if !ok2 return "", false;
                    r = 0x10000 + ((r - 0xD800) << 10) + (lo - 0xDC00);
                }
                tmp: [4]u8;
                n := strings.encode_rune(r, tmp);
                append(*b, ..sub(tmp, 0, n));
            case; array_add(*b, e);
        }
    }
    return "", false;
}
hex4 :: (p: *Parser) -> u32, bool {
    if p.i + 4 > p.s.count return 0, false;
    v, ok := strconv.parse_u64(sub(p.s, p.i, p.i + 4), 16);
    p.i += 4;
    return cast(u32) v, ok;
}

indent :: (b: *strings.Builder, opts: Marshal_Options, depth: int) {
    if !opts.pretty return;
    array_add(*b.buf, #char "\n");
    for 1..depth strings.write_string(b, "\t");
}
write_str :: (b: *strings.Builder, s: string) { strings.write_string(b, fmt.quote(s)); }
write :: (b: *strings.Builder, v: Any, opts: Marshal_Options, depth: int) {
    info := v.type;
    p := v.value_pointer;
    if info.type == {
        case .INTEGER; strings.write_string(b, tprint("%", v));
        case .FLOAT; strings.write_string(b, tprint("%", v));
        case .BOOL; strings.write_string(b, ifx (cast(*bool) p).* then "true" else "false");
        case .STRING; write_str(b, (cast(*string) p).*);
        case .ENUM; write_str(b, tprint("%", v));
        case .ARRAY;
            ai := cast(*Type_Info_Array) info;
            data: *u8; count: int;
            if ai.array_type == .FIXED { data = p; count = ai.array_count; }
            else { data = (cast(*[]u8) p).data; count = (cast(*[]u8) p).count; }
            array_add(*b.buf, #char "[");
            for i: 0..count-1 {
                if i array_add(*b.buf, #char ",");
                indent(b, opts, depth + 1);
                write(b, Any.{ai.element_type, data + i * ai.element_type.runtime_size}, opts, depth + 1);
            }
            if count indent(b, opts, depth);
            array_add(*b.buf, #char "]");
        case .STRUCT;
            si := cast(*Type_Info_Struct) info;
            if si.name == "Map" { write_map(b, v, si, opts, depth); return; }
            array_add(*b.buf, #char "{");
            n := 0;
            for m: si.members {
                if m.flags & .CONSTANT continue;
                if n array_add(*b.buf, #char ",");
                n += 1;
                indent(b, opts, depth + 1);
                write_str(b, m.name);
                strings.write_string(b, ifx opts.pretty then ": " else ":");
                write(b, Any.{m.type, p + m.offset_in_bytes}, opts, depth + 1);
            }
            if n indent(b, opts, depth);
            array_add(*b.buf, #char "}");
        case; strings.write_string(b, "null");
    }
}
// Map's using member `t: Table(K, V)`: walk its entries array, keys sorted.
write_map :: (b: *strings.Builder, v: Any, si: *Type_Info_Struct, opts: Marshal_Options, depth: int) {
    keys: [..]string; keys.allocator = temp;
    vals: [..]Any; vals.allocator = temp;
    table_info := cast(*Type_Info_Struct) si.members[0].type;
    entries_m: *Type_Info_Struct_Member;
    for * table_info.members if it.name == "entries" entries_m = it;
    ea := cast(*Type_Info_Array) entries_m.type;
    entry := cast(*Type_Info_Struct) ea.element_type;
    entries := cast(*[]u8) (v.value_pointer + si.members[0].offset_in_bytes + entries_m.offset_in_bytes);
    hash_m, key_m, val_m: *Type_Info_Struct_Member;
    for * entry.members { if it.name == "hash" hash_m = it; if it.name == "key" key_m = it; if it.name == "value" val_m = it; }
    for i: 0..entries.count-1 {
        e := entries.data + i * entry.runtime_size;
        h := (cast(*u32) (e + hash_m.offset_in_bytes)).*;
        if h < 2 continue;  // empty / removed slots
        array_add(*keys, (cast(*string) (e + key_m.offset_in_bytes)).*);
        array_add(*vals, Any.{val_m.type, e + val_m.offset_in_bytes});
    }
    order: [..]int; order.allocator = temp;
    for keys array_add(*order, it_index);
    for i: 1..order.count-1 { j := i; while j > 0 && keys[order[j]] < keys[order[j-1]] { order[j], order[j-1] = order[j-1], order[j]; j -= 1; } }
    array_add(*b.buf, #char "{");
    for o, n: order {
        if n array_add(*b.buf, #char ",");
        indent(b, opts, depth + 1);
        write_str(b, keys[o]);
        strings.write_string(b, ifx opts.pretty then ": " else ":");
        write(b, vals[o], opts, depth + 1);
    }
    if order.count indent(b, opts, depth);
    array_add(*b.buf, #char "}");
}
read :: (v: Value, info: *Type_Info, p: *void) {
    if info.type == {
        case .INTEGER;
        if v.kind != .Int && v.kind != .Float return;
        n: s64 = ifx v.kind == .Int then v.i else cast(s64) v.f;
        memcpy(p, *n, info.runtime_size);
        case .FLOAT;
        if v.kind != .Int && v.kind != .Float return;
        f: float64 = ifx v.kind == .Float then v.f else cast(float64) v.i;
        if info.runtime_size == 4 (cast(*float32) p).* = cast(float32) f; else (cast(*float64) p).* = f;
        case .BOOL; if v.kind == .Bool (cast(*bool) p).* = v.b;
        case .STRING; if v.kind == .String (cast(*string) p).* = copy_string(v.s);
        case .ENUM;
        if v.kind != .String return;
        e := cast(*Type_Info_Enum) info;
        for e.names if it == v.s { n := e.values[it_index]; memcpy(p, *n, info.runtime_size); }
        case .ARRAY;
        if v.kind != .List return;
        ai := cast(*Type_Info_Array) info;
        es := ai.element_type.runtime_size;
        if ai.array_type == .FIXED {
            for v.list if it_index < ai.array_count read(it, ai.element_type, p + it_index * es);
        } else {
            data := alloc(v.list.count * es);
            memset(data, 0, v.list.count * es);
            for v.list read(it, ai.element_type, data + it_index * es);
            s := cast(*[..]u8) p;
            s.data = data; s.count = v.list.count;
            if ai.array_type == .RESIZABLE { s.allocated = v.list.count; s.allocator = context.allocator; }
        }
        case .STRUCT;
        if v.kind != .Map return;
        si := cast(*Type_Info_Struct) info;
        if si.name == "Map" {
            // Only Map(string, string) is persisted.
            m := cast(*Map(string, string)) p;
            for k, x: v.map if x.kind == .String at(m, copy_string(k)).* = copy_string(x.s);
            return;
        }
        for m: si.members {
            if m.flags & .CONSTANT continue;
            x, ok := map_find(v.map, m.name);
            if ok read(x, m.type, p + m.offset_in_bytes);
        }
    }
}
