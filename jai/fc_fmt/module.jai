// printf with the original code's verbs (%d %s %v %x %q %f %c ...), over Jai's Any.
#import "Basic";
Basic :: #import "Basic";
#import "fc";
strings :: #import "fc_strings";

format :: (b: *strings.Builder, f: string, args: []Any) {
    ai := 0;
    i := 0;
    while i < f.count {
        c := f[i];
        // Odin's fmt escapes braces: "{{" and "}}" print one brace.
        if (c == #char "{" || c == #char "}") && i + 1 < f.count && f[i+1] == c { array_add(*b.buf, c); i += 2; continue; }
        if c != #char "%" { array_add(*b.buf, c); i += 1; continue; }
        i += 1;
        if i >= f.count break;
        if f[i] == #char "%" { array_add(*b.buf, #char "%"); i += 1; continue; }
        left, plus, zero, space, alt := false, false, false, false, false;
        while i < f.count {
            if f[i] == #char "-" left = true;
            else if f[i] == #char "+" plus = true;
            else if f[i] == #char "0" zero = true;
            else if f[i] == #char " " space = true;
            else if f[i] == #char "#" alt = true;
            else break;
            i += 1;
        }
        width, prec := -1, -1;
        if i < f.count && f[i] == #char "*" { width = any_int(args[ai]); ai += 1; i += 1; }
        while i < f.count && f[i] >= #char "0" && f[i] <= #char "9" { if width < 0 width = 0; width = width * 10 + f[i] - #char "0"; i += 1; }
        if i < f.count && f[i] == #char "." {
            i += 1; prec = 0;
            if i < f.count && f[i] == #char "*" { prec = any_int(args[ai]); ai += 1; i += 1; }
            while i < f.count && f[i] >= #char "0" && f[i] <= #char "9" { prec = prec * 10 + f[i] - #char "0"; i += 1; }
        }
        if i >= f.count break;
        verb := f[i];
        i += 1;
        if ai >= args.count { strings.write_string(b, "%!(MISSING)"); continue; }
        a := args[ai];
        ai += 1;
        s := format_one(a, verb, prec, alt, plus);
        if zero && !left && width > s.count && verb != #char "s" && verb != #char "q" {
            neg := s.count > 0 && (s[0] == #char "-" || s[0] == #char "+");
            if neg array_add(*b.buf, s[0]);
            for 1..width - s.count array_add(*b.buf, #char "0");
            strings.write_string(b, ifx neg then sub_from(s, 1) else s);
            continue;
        }
        if !left for 1..width - s.count array_add(*b.buf, #char " ");
        strings.write_string(b, s);
        if left for 1..width - s.count array_add(*b.buf, #char " ");
    }
}

any_int :: (a: Any) -> int {
    info := a.type;
    if info.type == .INTEGER {
        ti := cast(*Type_Info_Integer) info;
        if ti.signed {
            if info.runtime_size == {
                case 1; return (cast(*s8) a.value_pointer).*;
                case 2; return (cast(*s16) a.value_pointer).*;
                case 4; return (cast(*s32) a.value_pointer).*;
                case; return (cast(*s64) a.value_pointer).*;
            }
        } else {
            if info.runtime_size == {
                case 1; return (cast(*u8) a.value_pointer).*;
                case 2; return (cast(*u16) a.value_pointer).*;
                case 4; return (cast(*u32) a.value_pointer).*;
                case; return cast,no_check(int) (cast(*u64) a.value_pointer).*;
            }
        }
    }
    if info.type == .ENUM {
        e := cast(*Type_Info_Enum) info;
        b: Any;
        b.type = e.internal_type;
        b.value_pointer = a.value_pointer;
        return any_int(b);
    }
    if info.type == .BOOL return ifx (cast(*bool) a.value_pointer).* then 1 else 0;
    return 0;
}

any_u64 :: (a: Any) -> u64 {
    info := a.type;
    if info.type == .INTEGER && !(cast(*Type_Info_Integer) info).signed && info.runtime_size == 8 return (cast(*u64) a.value_pointer).*;
    return cast,no_check(u64) any_int(a);
}

format_one :: (a: Any, verb: u8, prec: int, alt: bool, plus: bool) -> string {
    info := a.type;
    is_int := info.type == .INTEGER || (info.type == .ENUM && verb != #char "v" && verb != #char "s");
    if verb == #char "c" {
        r := cast(u32) any_int(a);
        tmp: [4]u8;
        n := strings.encode_rune(r, tmp);
        return copy_temporary_string(as_string(sub(tmp, 0, n)));
    }
    if is_int && (verb == #char "d" || verb == #char "i" || verb == #char "v" || verb == #char "x" || verb == #char "X" || verb == #char "b" || verb == #char "o" || verb == #char "u") {
        base := 10;
        if verb == #char "x" || verb == #char "X" base = 16;
        if verb == #char "b" base = 2;
        if verb == #char "o" base = 8;
        signed := info.type == .INTEGER && (cast(*Type_Info_Integer) info).signed;
        s: string;
        if !signed || base != 10 {
            v := any_u64(a);
            if signed && base != 10 && any_int(a) < 0 {
                s = Basic.tprint("-%", formatInt(cast(u64) -any_int(a), base = base, minimum_digits = max(prec, 1)));
            } else {
                s = Basic.tprint("%", formatInt(v, base = base, minimum_digits = max(prec, 1)));
            }
        } else {
            s = Basic.tprint("%", formatInt(any_int(a), minimum_digits = max(prec, 1)));
            if plus && any_int(a) >= 0 s = Basic.tprint("+%", s);
        }
        if verb == #char "x" s = to_lower_copy_temp(s);
        if alt && base == 16 s = Basic.tprint("0x%", s);
        return s;
    }
    if info.type == .FLOAT {
        v: float64 = ifx info.runtime_size == 4 then cast(float64) (cast(*float32) a.value_pointer).* else (cast(*float64) a.value_pointer).*;
        if verb == #char "e" || verb == #char "E" return Basic.tprint("%", formatFloat(v, trailing_width = ifx prec < 0 then 6 else prec, mode = .SCIENTIFIC));
        if verb == #char "g" || verb == #char "G" || (verb == #char "v" && prec < 0) return Basic.tprint("%", formatFloat(v, trailing_width = -1, zero_removal = .YES));
        s := Basic.tprint("%", formatFloat(v, trailing_width = ifx prec < 0 then 6 else prec, zero_removal = .NO));
        if plus && v >= 0 s = Basic.tprint("+%", s);
        return s;
    }
    if info.type == .STRING {
        s := (cast(*string) a.value_pointer).*;
        if prec >= 0 && prec < s.count s = sub(s, 0, prec);
        if verb == #char "q" return quote(s);
        if verb == #char "x" || verb == #char "X" return hex_bytes(to_bytes(s), verb == #char "X");
        return s;
    }
    if info.type == .POINTER {
        p := (cast(**u8) a.value_pointer).*;
        if verb == #char "s" && info == type_info(*u8) return to_string(p);
        return Basic.tprint("0x%", formatInt(cast(u64) p, base = 16));
    }
    if info.type == .ARRAY && (verb == #char "x" || verb == #char "X") {
        ai := cast(*Type_Info_Array) info;
        if ai.element_type == type_info(u8) {
            v: []u8;
            if ai.array_type == .FIXED { v.data = a.value_pointer; v.count = ai.array_count; }
            else v = (cast(*[]u8) a.value_pointer).*;
            return hex_bytes(v, verb == #char "X");
        }
    }
    if info.type == .TYPE return Basic.tprint("%", (cast(*Type) a.value_pointer).*);
    return Basic.tprint("%", a);
}

to_lower_copy_temp :: (s: string) -> string {
    r := copy_temporary_string(s);
    for i: 0..r.count-1 if r[i] >= #char "A" && r[i] <= #char "Z" r[i] += 32;
    return r;
}
hex_bytes :: (v: []u8, upper: bool) -> string {
    digits := ifx upper then "0123456789ABCDEF" else "0123456789abcdef";
    r := talloc_string(v.count * 2);
    for v { r[it_index*2] = digits[it >> 4]; r[it_index*2+1] = digits[it & 15]; }
    return r;
}
quote :: (s: string) -> string {
    b := strings.builder_make(temp);
    array_add(*b.buf, #char "\"");
    for c: cast([]u8) s {
        if c == #char "\"" strings.write_string(*b, "\\\"");
        else if c == #char "\\" strings.write_string(*b, "\\\\");
        else if c == #char "\n" strings.write_string(*b, "\\n");
        else if c == #char "\t" strings.write_string(*b, "\\t");
        else if c == #char "\r" strings.write_string(*b, "\\r");
        else if c < 0x20 strings.write_string(*b, Basic.tprint("\\u%", formatInt(c, base = 16, minimum_digits = 4)));
        else array_add(*b.buf, c);
    }
    array_add(*b.buf, #char "\"");
    return strings.to_string(b);
}

join_args :: (b: *strings.Builder, args: []Any, sep := " ") {
    for args {
        if it_index > 0 strings.write_string(b, sep);
        strings.write_string(b, format_one(it, #char "v", -1, false, false));
    }
}

tprintf :: (f: string, args: ..Any) -> string { b := strings.builder_make(temp); format(*b, f, args); return strings.to_string(b); }
tprintfln :: (f: string, args: ..Any) -> string { b := strings.builder_make(temp); format(*b, f, args); array_add(*b.buf, #char "\n"); return strings.to_string(b); }
aprintf :: (f: string, args: ..Any, allocator := context.allocator) -> string { b := strings.builder_make(allocator); format(*b, f, args); return strings.to_string(b); }
ctprintf :: (f: string, args: ..Any) -> *u8 { b := strings.builder_make(temp); format(*b, f, args); array_add(*b.buf, 0); return b.buf.data; }
caprintf :: (f: string, args: ..Any) -> *u8 { b := strings.builder_make(); format(*b, f, args); array_add(*b.buf, 0); return b.buf.data; }
tprint :: (args: ..Any, sep := " ") -> string { b := strings.builder_make(temp); join_args(*b, args, sep); return strings.to_string(b); }
aprint :: (args: ..Any, sep := " ") -> string { b := strings.builder_make(); join_args(*b, args, sep); return strings.to_string(b); }
sbprintf :: (b: *strings.Builder, f: string, args: ..Any) -> string { format(b, f, args); return strings.to_string(b); }
sbprintfln :: (b: *strings.Builder, f: string, args: ..Any) -> string { format(b, f, args); array_add(*b.buf, #char "\n"); return strings.to_string(b); }
sbprint :: (b: *strings.Builder, args: ..Any, sep := " ") -> string { join_args(b, args, sep); return strings.to_string(b); }
sbprintln :: (b: *strings.Builder, args: ..Any, sep := " ") -> string { join_args(b, args, sep); array_add(*b.buf, #char "\n"); return strings.to_string(b); }
bprintf :: (buf: []u8, f: string, args: ..Any) -> string {
    s := tprintf(f, ..args);
    n := copy(buf, s);
    return as_string(sub(buf, 0, n));
}

out :: (s: string, err: bool) { write_string(s, to_standard_error = err); }
printf :: (f: string, args: ..Any) { out(tprintf(f, ..args), false); }
printfln :: (f: string, args: ..Any) { out(tprintfln(f, ..args), false); }
eprintf :: (f: string, args: ..Any) { out(tprintf(f, ..args), true); }
eprintfln :: (f: string, args: ..Any) { out(tprintfln(f, ..args), true); }
print :: (args: ..Any, sep := " ") { out(tprint(..args, sep = sep), false); }
println :: (args: ..Any, sep := " ") { out(tprint(..args, sep = sep), false); out("\n", false); }
eprint :: (args: ..Any, sep := " ") { out(tprint(..args, sep = sep), true); }
eprintln :: (args: ..Any, sep := " ") { out(tprint(..args, sep = sep), true); out("\n", true); }
panicf :: (f: string, args: ..Any, loc := #caller_location) { panic(tprintf(f, ..args), loc); }
