// Small helpers every fastcord module imports: container and string glue the code base uses everywhere.
#import "Basic";
#import "String";
#import "Hash_Table";
#import "File";

len :: inline (a: $T) -> int {
    #if T == *u8 return c_style_strlen(a);
    else return a.count;
}
cap :: inline (a: [..]$T) -> int { return a.allocated; }

append :: (a: *[..]$T, items: ..T) -> int, *void {
    array_reserve(a, a.count + items.count);
    memcpy(a.data + a.count, items.data, items.count * size_of(T));
    a.count += items.count;
    return items.count, null;
}
append :: (a: *[..]u8, s: string) -> int, *void {
    array_reserve(a, a.count + s.count);
    memcpy(a.data + a.count, s.data, s.count);
    a.count += s.count;
    return s.count, null;
}
inject_at :: (a: *[..]$T, i: int, x: T) { array_insert_at(a, x, i); }
ordered_remove :: (a: *[..]$T, i: int) { array_ordered_remove_by_index(a, i); }
unordered_remove :: (a: *[..]$T, i: int) { array_unordered_remove_by_index(a, i); }
resize :: (a: *[..]$T, n: int) { array_resize(a, n); }
reserve :: (a: *[..]$T, n: int) { array_reserve(a, n); }
pop_front :: (a: *[..]$T) -> T { x := a.*[0]; array_ordered_remove_by_index(a, 0); return x; }

clear :: (a: *[..]$T) { a.count = 0; }

delete :: (s: string, allocator := context.allocator) { if s.data { push_allocator(allocator); free(s.data); } }
delete :: (a: []$T, allocator := context.allocator) { if a.data { push_allocator(allocator); free(a.data); } }
delete :: (a: [..]$T) { array_free(a); }
delete :: (c: *u8, allocator := context.allocator) { if c { push_allocator(allocator); free(c); } }

// Hash map; `for k, v: m` iterates key first (`for *k, v: m` makes v a pointer).
Map :: struct(K: Type, V: Type) { using t: Table(K, V); }
for_expansion :: (m: *Map, body: Code, flags: For_Flags) #expand {
    #if flags & .POINTER { for * v, k: m.t { `it := k; `it_index := v; #insert body; } }
    else { for v, k: m.t { `it := k; `it_index := v; #insert body; } }
}
get :: inline (m: Map, k: m.K) -> m.V { mm := m; p := table_find_pointer(*mm.t, k); if p return p.*; z: m.V; return z; }
at :: inline (m: *Map, k: m.K) -> *m.V { p := find_or_add(*m.t, k); return p; }
map_find :: inline (m: Map, k: m.K) -> m.V, bool { mm := m; p := table_find_pointer(*mm.t, k); if p return p.*, true; z: m.V; return z, false; }
map_find_ptr :: inline (m: *Map, k: m.K) -> *m.V, bool { p := table_find_pointer(*m.t, k); return p, p != null; }
map_set :: inline (m: *Map, k: m.K, v: m.V) { table_set(*m.t, k, v); }
delete_key :: inline (m: *Map, k: m.K) -> m.K, m.V { ok, v := table_remove(*m.t, k); return k, v; }
has :: inline (m: Map, k: m.K) -> bool { mm := m; return table_find_pointer(*mm.t, k) != null; }
reserve :: (m: *Map, n: int) { table_ensure_space(*m.t, n); }
clear :: (m: *Map) { table_reset(*m.t); }
delete :: (m: Map) { mm := m; deinit(*mm.t); }
// The same indexing for arrays, where a field name is a map in one struct and an array in another.
get :: inline (a: []$T, i: $I) -> T { return a[i]; }
get :: inline (a: [$N]$T, i: $I) -> T { return a[i]; }
at :: inline (a: *[..]$T, i: $I) -> *T { return *a.*[i]; }
at :: inline (a: *[]$T, i: $I) -> *T { return *a.*[i]; }
at :: inline (a: *[$N]$T, i: $I) -> *T { return *a.*[i]; }

// Slicing: a[lo:hi] in the original code.
sub :: inline (s: string, lo: $A, hi: $B) -> string { r: string = ---; r.data = s.data + lo; r.count = cast(int) hi - cast(int) lo; return r; }
sub :: inline (a: []$T, lo: $A, hi: $B) -> []T { r: []T = ---; r.data = a.data + lo; r.count = cast(int) hi - cast(int) lo; return r; }
sub :: inline (p: *$T, lo: $A, hi: $B) -> []T { r: []T = ---; r.data = p + lo; r.count = cast(int) hi - cast(int) lo; return r; }
sub_from :: inline (s: string, lo: $A) -> string { return sub(s, lo, s.count); }
sub_from :: inline (a: []$T, lo: $A) -> []T { return sub(a, lo, a.count); }
view :: inline (a: []$T) -> []T { return a; }

as_string :: inline (b: []u8) -> string { s: string = ---; s.data = b.data; s.count = b.count; return s; }
as_string :: inline (s: string) -> string { return s; }
as_string :: inline (p: *u8) -> string { return to_string(p); }
to_bytes :: inline (s: string) -> []u8 { b: []u8 = ---; b.data = s.data; b.count = s.count; return b; }
to_cstring :: inline (s: string) -> *u8 { return s.data; }
to_cstring :: inline (p: *u8) -> *u8 { return p; }
raw_data :: inline (a: $T) -> type_of(a.data) { return a.data; }

transmute :: inline ($T: Type, x: $S) -> T { y := x; return (cast(*T) *y).*; }
zero :: inline ($T: Type) -> T { r: T; return r; }

// or_return: an error value means failure when it is false, non-zero, or non-null.
failed :: inline (e: bool) -> bool { return !e; }
failed :: inline (e: $T) -> bool #modify { return (cast(*Type_Info) T).type == .ENUM; } { return cast(s64) e != 0; }
failed :: inline (e: *$T) -> bool { return e != null; }
or_else :: (c: Code, d: $T) -> T #expand { v, ok := #insert c; if ok return v; return d; }

make_slice :: ($T: Type, n: int, allocator := context.allocator) -> []T {
    push_allocator(allocator);
    return NewArray(n, T);
}
make_dynamic :: ($T: Type, n: int, c := -1, allocator := context.allocator) -> [..]T {
    a: [..]T;
    a.allocator = allocator;
    array_reserve(*a, ifx c < n then n else c);
    array_resize(*a, n);
    return a;
}
new :: ($T: Type, allocator := context.allocator) -> *T { push_allocator(allocator); return New(T); }
new_clone :: (x: $T, allocator := context.allocator) -> *T { push_allocator(allocator); p := New(T, false); p.* = x; return p; }
clone :: (s: string, allocator := context.allocator) -> string { push_allocator(allocator); return copy_string(s); }
clone :: (a: []$T, allocator := context.allocator) -> []T {
    push_allocator(allocator);
    r := NewArray(a.count, T, false);
    memcpy(r.data, a.data, a.count * size_of(T));
    return r;
}

copy :: (dst: []$T, src: []T) -> int { n := min(dst.count, src.count); memcpy(dst.data, src.data, n * size_of(T)); return n; }
copy :: (dst: []u8, src: string) -> int { n := min(dst.count, src.count); memcpy(dst.data, src.data, n); return n; }

abs :: inline (x: $T) -> T { return ifx x < 0 then -x else x; }

panic :: (msg: string, loc := #caller_location) { assert(false, "%", msg, loc = loc); }
unreachable :: (loc := #caller_location) -> void { assert(false, "unreachable", loc = loc); }

enum_count :: ($E: Type) -> int { return enum_highest_value(E) + 1; }
load_file :: (path: string, dir: string) -> string #compile_time {
    s, ok := read_entire_file(tprint("%/%", dir, path));
    assert(ok, "can't load %/%", dir, path);
    return s;
}

default_context :: () -> type_of(context) { c: type_of(context); return c; }

// `x in flags` for enum_flags sets.
has :: inline (f: $E, x: E) -> bool #modify { ti := cast(*Type_Info) E; return ti.type == .ENUM && ((cast(*Type_Info_Enum) ti).enum_type_flags & .FLAGS) != 0; } { return (f & x) != 0; }

Load_Directory_File :: struct { name: string; data: string; }
load_directory :: (path: string, dir: string) -> []Load_Directory_File #compile_time {
    FU :: #import "File_Utilities";
    out: [..]Load_Directory_File;
    full := tprint("%/%", dir, path);
    FU.visit_files(full, false, *out, (info: *FU.File_Visit_Info, out: *[..]Load_Directory_File) {
        array_add(out, .{copy_string(info.short_name), read_entire_file(info.full_name)});
    });
    return out;
}

// Integer and float limits (Odin's min(T) / max(T)).
Math :: #import "Math";
S8_MIN :: Math.S8_MIN; S8_MAX :: Math.S8_MAX; U8_MAX :: Math.U8_MAX;
S16_MIN :: Math.S16_MIN; S16_MAX :: Math.S16_MAX; U16_MAX :: Math.U16_MAX;
S32_MIN :: Math.S32_MIN; S32_MAX :: Math.S32_MAX; U32_MAX :: Math.U32_MAX;
S64_MIN :: Math.S64_MIN; S64_MAX :: Math.S64_MAX; U64_MAX :: Math.U64_MAX;
FLOAT32_MAX :: Math.FLOAT32_MAX; FLOAT64_MAX :: Math.FLOAT64_MAX; FLOAT32_MIN :: -Math.FLOAT32_MAX; FLOAT64_MIN :: -Math.FLOAT64_MAX;
U8_MIN :: 0; U16_MIN :: 0; U32_MIN :: 0; U64_MIN :: 0;
