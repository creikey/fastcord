#import "Basic";
S :: #import "String";
#import "fc";

Builder :: struct { buf: [..]u8; }

builder_make :: (allocator := context.allocator) -> Builder { b: Builder; b.buf.allocator = allocator; return b; }
builder_make :: (n: int, allocator := context.allocator) -> Builder { b := builder_make(allocator); array_reserve(*b.buf, n); return b; }
builder_from_bytes :: (backing: []u8) -> Builder { b: Builder; b.buf.data = backing.data; b.buf.allocated = backing.count; return b; }
builder_destroy :: (b: *Builder) { array_free(b.buf); b.buf = .[]; }
builder_reset :: (b: *Builder) { b.buf.count = 0; }
builder_len :: (b: Builder) -> int { return b.buf.count; }
to_string :: (b: Builder) -> string { return as_string(b.buf); }
write_string :: (b: *Builder, s: string) -> int { n := append(*b.buf, s); return n; }
write_bytes :: (b: *Builder, s: []u8) -> int { n := append(*b.buf, ..s); return n; }
write_byte :: (b: *Builder, c: u8) -> int { array_add(*b.buf, c); return 1; }
write_rune :: (b: *Builder, r: u32) -> int, bool {
    tmp: [4]u8;
    n := encode_rune(r, tmp);
    append(*b.buf, ..sub(tmp, 0, n));
    return n, true;
}
write_int :: (b: *Builder, i: int, base := 10) -> int { return write_string(b, tprint("%", formatInt(i, base = base))); }
write_i64 :: (b: *Builder, i: s64, base := 10) -> int { return write_string(b, tprint("%", formatInt(i, base = base))); }
write_u64 :: (b: *Builder, i: u64, base := 10) -> int { return write_string(b, tprint("%", formatInt(i, base = base))); }

encode_rune :: (r: u32, out: []u8) -> int {
    if r < 0x80 { out[0] = xx r; return 1; }
    if r < 0x800 { out[0] = xx (0xC0 | (r >> 6)); out[1] = xx (0x80 | (r & 0x3F)); return 2; }
    if r < 0x10000 {
        out[0] = xx (0xE0 | (r >> 12)); out[1] = xx (0x80 | ((r >> 6) & 0x3F)); out[2] = xx (0x80 | (r & 0x3F));
        return 3;
    }
    out[0] = xx (0xF0 | (r >> 18)); out[1] = xx (0x80 | ((r >> 12) & 0x3F));
    out[2] = xx (0x80 | ((r >> 6) & 0x3F)); out[3] = xx (0x80 | (r & 0x3F));
    return 4;
}

clone :: (s: string, allocator := context.allocator) -> string { push_allocator(allocator); return copy_string(s); }
clone_from_cstring :: (c: *u8, allocator := context.allocator) -> string { push_allocator(allocator); return copy_string(to_string(c)); }
clone_to_cstring :: (s: string, allocator := context.allocator) -> *u8 { push_allocator(allocator); return to_c_string(s); }
concatenate :: (a: []string, allocator := context.allocator) -> string { push_allocator(allocator); return S.join(..a); }
join :: (a: []string, sep: string, allocator := context.allocator) -> string { push_allocator(allocator); return S.join(..a, separator = sep); }
repeat :: (s: string, n: int, allocator := context.allocator) -> string {
    b := builder_make(allocator);
    for 1..n write_string(*b, s);
    return to_string(b);
}

has_prefix :: inline (s: string, p: string) -> bool { return S.begins_with(s, p); }
has_suffix :: inline (s: string, p: string) -> bool { return S.ends_with(s, p); }
contains :: inline (s: string, sub: string) -> bool { return S.contains(s, sub); }
contains_rune :: (s: string, r: u32) -> bool { return index_rune(s, r) >= 0; }
contains_any :: (s: string, chars: string) -> bool { return index_any(s, chars) >= 0; }
index :: inline (s: string, sub: string) -> int { return S.find_index_from_left(s, sub); }
last_index :: inline (s: string, sub: string) -> int { return S.find_index_from_right(s, sub); }
index_byte :: inline (s: string, c: u8) -> int { return S.find_index_from_left(s, c); }
last_index_byte :: inline (s: string, c: u8) -> int { return S.find_index_from_right(s, c); }
index_rune :: (s: string, r: u32) -> int {
    if r < 0x80 return index_byte(s, xx r);
    tmp: [4]u8;
    n := encode_rune(r, tmp);
    return index(s, as_string(sub(tmp, 0, n)));
}
index_any :: (s: string, chars: string) -> int {
    for i: 0..s.count-1 if index_byte(chars, s[i]) >= 0 return i;
    return -1;
}
last_index_any :: (s: string, chars: string) -> int {
    for < i: s.count-1..0 if index_byte(chars, s[i]) >= 0 return i;
    return -1;
}
count :: (s: string, sub_: string) -> int {
    n, i := 0, 0;
    while true {
        j := index(sub_from(s, i), sub_);
        if j < 0 || sub_.count == 0 break;
        n += 1; i += j + sub_.count;
    }
    return n;
}
equal_fold :: inline (a: string, b: string) -> bool { return S.equal_nocase(a, b); }
compare :: inline (a: string, b: string) -> int { return S.compare(a, b); }

is_space :: inline (c: u8) -> bool { return c == #char " " || c == #char "\t" || c == #char "\n" || c == #char "\r" || c == 11 || c == 12; }
trim_space :: (s: string) -> string { return trim_right_space(trim_left_space(s)); }
trim_left_space :: (s: string) -> string { i := 0; while i < s.count && is_space(s[i]) i += 1; return sub_from(s, i); }
trim_right_space :: (s: string) -> string { j := s.count; while j > 0 && is_space(s[j-1]) j -= 1; return sub(s, 0, j); }
trim_left :: (s: string, cut: string) -> string { i := 0; while i < s.count && index_byte(cut, s[i]) >= 0 i += 1; return sub_from(s, i); }
trim_right :: (s: string, cut: string) -> string { j := s.count; while j > 0 && index_byte(cut, s[j-1]) >= 0 j -= 1; return sub(s, 0, j); }
trim :: (s: string, cut: string) -> string { return trim_right(trim_left(s, cut), cut); }
trim_prefix :: (s: string, p: string) -> string { return ifx has_prefix(s, p) then sub_from(s, p.count) else s; }
trim_suffix :: (s: string, p: string) -> string { return ifx has_suffix(s, p) then sub(s, 0, s.count - p.count) else s; }

to_lower :: (s: string, allocator := context.allocator) -> string { push_allocator(allocator); return S.to_lower_copy(s); }
to_upper :: (s: string, allocator := context.allocator) -> string { push_allocator(allocator); return S.to_upper_copy(s); }

// replace_all / replace / remove_all return (result, allocated) like the original.
replace :: (s: string, old: string, new_: string, n: int, allocator := context.allocator) -> string, bool {
    if old.count == 0 || index(s, old) < 0 return s, false;
    b := builder_make(allocator);
    i, done := 0, 0;
    while n < 0 || done < n {
        j := index(sub_from(s, i), old);
        if j < 0 break;
        write_string(*b, sub(s, i, i + j));
        write_string(*b, new_);
        i += j + old.count;
        done += 1;
    }
    write_string(*b, sub_from(s, i));
    return to_string(b), true;
}
replace_all :: (s: string, old: string, new_: string, allocator := context.allocator) -> string, bool { a, b := replace(s, old, new_, -1, allocator); return a, b; }
remove_all :: (s: string, key: string, allocator := context.allocator) -> string, bool { a, b := replace(s, key, "", -1, allocator); return a, b; }

split :: (s: string, sep: string, allocator := context.allocator) -> []string {
    out: [..]string;
    out.allocator = allocator;
    i := 0;
    while true {
        j := index(sub_from(s, i), sep);
        if j < 0 || sep.count == 0 { array_add(*out, sub_from(s, i)); break; }
        array_add(*out, sub(s, i, i + j));
        i += j + sep.count;
    }
    return out;
}
split_n :: (s: string, sep: string, n: int, allocator := context.allocator) -> []string {
    out: [..]string;
    out.allocator = allocator;
    i := 0;
    while true {
        j := index(sub_from(s, i), sep);
        if j < 0 || out.count == n - 1 { array_add(*out, sub_from(s, i)); break; }
        array_add(*out, sub(s, i, i + j));
        i += j + sep.count;
    }
    return out;
}
split_lines :: (s: string, allocator := context.allocator) -> []string {
    out := split(s, "\n", allocator);
    for * out if it.count && it.*[it.count-1] == #char "\r" it.count -= 1;
    return out;
}
fields :: (s: string, allocator := context.allocator) -> []string {
    out: [..]string;
    out.allocator = allocator;
    rest := s;
    while true {
        f, ok := fields_iterator(*rest);
        if !ok break;
        array_add(*out, f);
    }
    return out;
}
split_iterator :: (s: *string, sep: string) -> string, bool {
    if s.data == null return "", false;
    j := index(s.*, sep);
    if j < 0 { r := s.*; s.* = ""; s.data = null; return r, true; }
    r := sub(s.*, 0, j);
    s.* = sub_from(s.*, j + sep.count);
    return r, true;
}
split_lines_iterator :: (s: *string) -> string, bool {
    if s.count == 0 return "", false;
    j := index_byte(s.*, #char "\n");
    r: string;
    if j < 0 { r = s.*; s.* = ""; }
    else { r = sub(s.*, 0, j); s.* = sub_from(s.*, j + 1); }
    if r.count && r[r.count-1] == #char "\r" r.count -= 1;
    return r, true;
}
fields_iterator :: (s: *string) -> string, bool {
    t := trim_left_space(s.*);
    if t.count == 0 { s.* = ""; return "", false; }
    i := 0;
    while i < t.count && !is_space(t[i]) i += 1;
    s.* = sub_from(t, i);
    return sub(t, 0, i), true;
}
