#import "Basic";
#import "fc";
strings :: #import "fc_strings";
RUNE_ERROR :: 0xFFFD;
decode_rune_in_string :: (s: string) -> u32, int {
    if s.count == 0 return RUNE_ERROR, 0;
    c := s[0];
    if c < 0x80 return c, 1;
    n := ifx c >= 0xF0 then 4 else ifx c >= 0xE0 then 3 else ifx c >= 0xC0 then 2 else 0;
    if n == 0 || n > s.count return RUNE_ERROR, 1;
    r: u32 = cast(u32) (c & (0x7F >> n));
    for i: 1..n-1 {
        if (s[i] & 0xC0) != 0x80 return RUNE_ERROR, 1;
        r = (r << 6) | (cast(u32) (s[i] & 0x3F));
    }
    return r, n;
}
decode_rune :: (b: []u8) -> u32, int { r, n := decode_rune_in_string(as_string(b)); return r, n; }
decode_last_rune_in_string :: (s: string) -> u32, int {
    if s.count == 0 return RUNE_ERROR, 0;
    i := s.count - 1;
    while i > 0 && s.count - i < 4 && s[i] & 0xC0 == 0x80 i -= 1;
    r, n := decode_rune_in_string(sub_from(s, i));
    if i + n != s.count return RUNE_ERROR, 1;
    return r, n;
}
rune_count_in_string :: (s: string) -> int { n := 0; for c: cast([]u8) s if c & 0xC0 != 0x80 n += 1; return n; }
rune_count :: (b: []u8) -> int { return rune_count_in_string(as_string(b)); }
rune_size :: (r: u32) -> int { return ifx r < 0x80 then 1 else ifx r < 0x800 then 2 else ifx r < 0x10000 then 3 else 4; }
encode_rune :: (r: u32) -> [4]u8, int {
    b: [4]u8;
    n := strings.encode_rune(r, b);
    return b, n;
}
runes_to_string :: (rs: []u32, allocator := context.allocator) -> string {
    out: [..]u8; out.allocator = allocator;
    for rs { b, n := encode_rune(it); append(*out, ..sub(b, 0, n)); }
    return as_string(out);
}
// Runes as a for-loop source: `for r: runes(s)`, it_index = byte offset.
Runes :: struct { s: string; }
runes :: (s: string) -> Runes { return .{s}; }
for_expansion :: (r: Runes, body: Code, flags: For_Flags) #expand {
    i := 0;
    while i < r.s.count {
        `it, n := decode_rune_in_string(sub_from(r.s, i));
        `it_index := i;
        i += n;
        #insert body;
    }
}

// Extended grapheme clusters, simplified: a base rune plus combining marks, variation selectors,
// skin tones, ZWJ sequences, keycaps, tags, and regional-indicator pairs.
Grapheme_Iterator :: struct { s: string; pos: int; }
decode_grapheme_iterator_make :: (s: string) -> Grapheme_Iterator { return .{s = s}; }
extends :: (r: u32) -> bool {
    return (r >= 0x300 && r <= 0x36F) || (r >= 0x1AB0 && r <= 0x1AFF) || (r >= 0x1DC0 && r <= 0x1DFF) || (r >= 0x20D0 && r <= 0x20FF)
        || (r >= 0xFE00 && r <= 0xFE0F) || (r >= 0xFE20 && r <= 0xFE2F) || (r >= 0x1F3FB && r <= 0x1F3FF) || (r >= 0xE0020 && r <= 0xE007F)
        || (r >= 0xE0100 && r <= 0xE01EF) || r == 0x200D || r == 0x20E3;
}
decode_grapheme_iterate :: (it: *Grapheme_Iterator) -> string, int, bool {
    if it.pos >= it.s.count return "", 0, false;
    start := it.pos;
    r, n := decode_rune_in_string(sub_from(it.s, it.pos));
    it.pos += n;
    if r == #char "\r" && it.pos < it.s.count && it.s[it.pos] == #char "\n" it.pos += 1;
    ri := r >= 0x1F1E6 && r <= 0x1F1FF;
    prev := r;
    while it.pos < it.s.count {
        r2, n2 := decode_rune_in_string(sub_from(it.s, it.pos));
        if ri && r2 >= 0x1F1E6 && r2 <= 0x1F1FF { it.pos += n2; ri = false; prev = r2; continue; }
        if extends(r2) || prev == 0x200D { it.pos += n2; prev = r2; continue; }
        break;
    }
    return sub(it.s, start, it.pos), rune_count_in_string(sub(it.s, start, it.pos)), true;
}
