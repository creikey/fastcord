// DEFLATE / zlib / gzip decoding through the vendored Wuffs (vendor/wuffs/fc_wuffs.c).
#import "Basic";
#import "fc";
bytes :: #import "fc_bytes";

wuffs :: #library,no_dll "../../build/fc_vendor";
fc_inflate_state_size :: () -> u64 #foreign wuffs;
fc_inflate_init :: (state: *void, kind: s32) -> s32 #foreign wuffs;
fc_inflate_step :: (state: *void, src: *u8, src_len: u64, dst: *u8, dst_len: u64, consumed: *u64, produced: *u64) -> s32 #foreign wuffs;

Kind :: enum s32 { Raw :: 0; Zlib :: 1; Gzip :: 2; }
Error :: enum { None; Corrupt; Too_Large; }

// Inflater keeps a decoder (and its history window) across feed calls.
Inflater :: struct { state: []u8; }
inflater_init :: (f: *Inflater, kind: Kind) {
    if !f.state.count f.state = NewArray(cast(int) fc_inflate_state_size(), u8);
    fc_inflate_init(f.state.data, xx kind);
}
inflater_destroy :: (f: *Inflater) { array_free(f.state); f.state = .[]; }
// feed decodes all of src, appending to out; ok is false on corrupt input or past max_out bytes.
feed :: (f: *Inflater, src: []u8, out: *[..]u8, max_out := -1) -> ended: bool, ok: bool {
    s := src;
    while true {
        if out.allocated - out.count < 4096 array_reserve(out, max(out.allocated * 2, out.count + 16384));
        used, made: u64;
        r := fc_inflate_step(f.state.data, s.data, xx s.count, out.data + out.count, xx (out.allocated - out.count), *used, *made);
        out.count += cast(int) made;
        s = sub_from(s, used);
        if max_out >= 0 && out.count > max_out return false, false;
        if r == 5 return true, true;                  // end of stream
        if r == 0 && s.count == 0 return false, true;  // needs more input
        if r != 0 && r != 1 return false, false;
    }
    return false, false;
}

inflate :: (input: []u8, buf: *bytes.Buffer, raw := false, expected_output_size := -1) -> Error {
    f: Inflater;
    inflater_init(*f, ifx raw then .Raw else .Zlib);
    defer inflater_destroy(*f);
    if expected_output_size > 0 array_reserve(*buf.buf, buf.buf.count + expected_output_size);
    ended, ok := feed(*f, input, *buf.buf);
    return ifx ok && ended then .None else .Corrupt;
}
