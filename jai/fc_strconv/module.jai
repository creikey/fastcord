#import "Basic";
#import "fc";
parse_int :: (s: string, base := 0) -> int, bool { a, b := parse_i64(s, base); return a, b; }
parse_i64 :: (s: string, base := 0) -> s64, bool {
    neg := s.count > 0 && s[0] == #char "-";
    t := ifx s.count > 0 && (s[0] == #char "-" || s[0] == #char "+") then sub_from(s, 1) else s;
    v, ok := parse_u64(t, base);
    if !ok || v > cast(u64) S64_MAX + cast(u64) neg return 0, false;
    return ifx neg then -cast,no_check(s64) v else cast(s64) v, true;
}
parse_u64 :: (s: string, base := 0) -> u64, bool {
    b := base;
    t := s;
    if b == 0 {
        b = 10;
        if t.count > 2 && t[0] == #char "0" {
            if t[1] == #char "x" || t[1] == #char "X" { b = 16; t = sub_from(t, 2); }
            else if t[1] == #char "b" || t[1] == #char "B" { b = 2; t = sub_from(t, 2); }
            else if t[1] == #char "o" || t[1] == #char "O" { b = 8; t = sub_from(t, 2); }
        }
    }
    if t.count == 0 return 0, false;
    v: u64;
    for c: cast([]u8) t {
        if c == #char "_" continue;
        d: u64;
        if c >= #char "0" && c <= #char "9" d = c - #char "0";
        else if c >= #char "a" && c <= #char "z" d = c - #char "a" + 10;
        else if c >= #char "A" && c <= #char "Z" d = c - #char "A" + 10;
        else return 0, false;
        if d >= cast(u64) b return 0, false;
        if v > (U64_MAX - d) / cast(u64) b return 0, false;
        v = v * cast(u64) b + d;
    }
    return v, true;
}
parse_u64_of_base :: (s: string, base: int) -> u64, bool { a, b := parse_u64(s, base); return a, b; }
parse_f64 :: (s: string) -> float64, bool {
    if s.count == 0 return 0, false;
    v, ok, rest := string_to_float64(s);
    return v, ok && rest.count == 0;
}
parse_f32 :: (s: string) -> float32, bool { v, ok := parse_f64(s); return cast(float32) v, ok; }
write_uint :: (buf: []u8, v: u64, base: int) -> string { return as_string(sub(buf, 0, copy(buf, tprint("%", formatInt(v, base = base))))); }
write_int :: (buf: []u8, v: s64, base: int) -> string { return as_string(sub(buf, 0, copy(buf, tprint("%", formatInt(v, base = base))))); }
// fmt 'f' / 'g' with precision -1: the shortest form that round-trips.
write_float :: (buf: []u8, v: float64, fmt: u8, prec: int, bit_size: int) -> string {
    s := tprint("%", formatFloat(v, trailing_width = prec, zero_removal = ifx prec < 0 then .YES else .NO));
    return as_string(sub(buf, 0, copy(buf, s)));
}
