// Protocol Buffers wire format: a field reader and an appending writer.
#import "Basic";

Wire_Type :: enum u8 { Varint :: 0; I64 :: 1; Len :: 2; I32 :: 5; }

Field :: struct {
    num: u32;
    wire: Wire_Type;
    value: u64;   // varint / fixed value
    bytes: []u8;  // Len payload (submessage, string, packed)
}

Reader :: struct {
    buf: []u8;
    pos: int;
}

read_varint :: (r: *Reader) -> u64, bool {
    v, shift: u64;
    while r.pos < r.buf.count && shift < 64 {
        b := r.buf[r.pos];
        r.pos += 1;
        v |= (cast(u64) (b & 0x7f)) << shift;
        if !(b & 0x80) return v, true;
        shift += 7;
    }
    return 0, false;
}

// next reads the next field; false at the end or on malformed input.
next :: (r: *Reader) -> Field, bool {
    if r.pos >= r.buf.count return .{}, false;
    tag, ok := read_varint(r);
    if !ok return .{}, false;
    f := Field.{num = cast(u32) (tag >> 3), wire = cast(Wire_Type) (tag & 7)};
    if f.wire == {
      case .Varint;
        f.value, ok = read_varint(r);
        if !ok return f, false;
      case .I64;
        if r.pos + 8 > r.buf.count return .{}, false;
        f.value = le(r.buf.data + r.pos, 8);
        r.pos += 8;
      case .I32;
        if r.pos + 4 > r.buf.count return .{}, false;
        f.value = le(r.buf.data + r.pos, 4);
        r.pos += 4;
      case .Len;
        n:, ok = read_varint(r);
        if !ok return f, false;
        if n > cast(u64) (r.buf.count - r.pos) return .{}, false;
        f.bytes = array_view(r.buf, r.pos, xx n);
        r.pos += xx n;
      case;
        return .{}, false;
    }
    return f, true;
}

// find returns the first field with this number at the top level of buf.
find :: (buf: []u8, num: u32) -> Field, bool {
    r := Reader.{buf = buf};
    while true {
        f, ok := next(*r);
        if !ok break;
        if f.num == num return f, true;
    }
    return .{}, false;
}

// find_path looks through nested submessages: find_path(buf, 2, 1) = field 1 of message field 2.
find_path :: (buf: []u8, path: ..u32) -> Field, bool {
    f: Field;
    cur := buf;
    for num: path {
        ok: bool;
        f, ok = find(cur, num);
        if !ok return .{}, false;
        if it_index < path.count - 1 {
            if f.wire != .Len return .{}, false;
            cur = f.bytes;
        }
    }
    return f, true;
}

// packed_fixed64 decodes a packed repeated fixed64 (guild folder guild_ids) into context.allocator.
packed_fixed64 :: (b: []u8) -> []u64 {
    out := NewArray(b.count / 8, u64, false);
    for * out it.* = le(b.data + it_index * 8, 8);
    return out;
}

Writer :: struct {
    buf: [..]u8;
}

write_varint :: (w: *Writer, value: u64) {
    v := value;
    while v >= 0x80 {
        array_add(*w.buf, (cast(u8) v) | 0x80);
        v >>= 7;
    }
    array_add(*w.buf, cast(u8) v);
}
write_tag :: (w: *Writer, num: u32, wire: Wire_Type) { write_varint(w, ((cast(u64) num) << 3) | (cast(u64) wire)); }
write_uint :: (w: *Writer, num: u32, v: u64) {
    write_tag(w, num, .Varint);
    write_varint(w, v);
}
write_bytes :: (w: *Writer, num: u32, b: []u8) {
    write_tag(w, num, .Len);
    write_varint(w, xx b.count);
    array_add(*w.buf, ..b);
}
write_string :: (w: *Writer, num: u32, s: string) { write_bytes(w, num, cast([]u8) s); }

#scope_file
le :: (p: *u8, n: int) -> u64 {
    v: u64;
    for i: 0..n-1 v |= (cast(u64) p[i]) << (8 * i);
    return v;
}
