// DEFLATE / zlib / gzip decoding through the vendored Wuffs (vendor/wuffs/fc_wuffs.c).
#import "Basic";

Kind :: enum s32 { RAW :: 0; ZLIB :: 1; GZIP :: 2; }

// An Inflater keeps its decoder, and so its 32 KiB history, across feeds (WebSocket permessage-deflate).
Inflater :: struct { state: []u8; }
init :: (f: *Inflater, kind: Kind) {
    if !f.state.count f.state = NewArray(cast(int) fc_inflate_state_size(), u8);
    fc_inflate_init(f.state.data, xx kind);
}
destroy :: (f: *Inflater) { array_free(f.state); f.state = .[]; }

// feed decodes all of src, appending to out. ok is false on corrupt input or when out passes max_out bytes.
feed :: (f: *Inflater, src: []u8, out: *[..]u8, max_out := -1) -> ended: bool, ok: bool {
    s := src;
    while true {
        if out.allocated - out.count < 4096 {
            want := max(out.allocated * 2, out.count + 16384);
            if max_out >= 0 want = min(want, max_out + 16384); // never reserve far past the cap
            array_reserve(out, want);
        }
        used, made: u64;
        r := fc_inflate_step(f.state.data, s.data, xx s.count, out.data + out.count, xx (out.allocated - out.count), *used, *made);
        out.count += cast(int) made;
        s.data += used; s.count -= xx used;
        if max_out >= 0 && out.count > max_out return false, false;
        if r == FC_END return true, true;
        if r == FC_OK && s.count == 0 return false, true;  // needs more input
        if r != FC_OK && r != FC_TRUNCATED return false, false;
    }
    return false, false;
}

// inflate decodes one complete stream into context.allocator; false on corrupt or truncated input.
inflate :: (data: []u8, kind: Kind, max_out := -1) -> []u8, bool {
    f: Inflater;
    init(*f, kind);
    defer destroy(*f);
    out: [..]u8;
    ended, ok := feed(*f, data, *out, max_out);
    if ok && ended return out, true;
    array_free(out);
    return .[], false;
}

#scope_file
FC_OK :: 0;
FC_TRUNCATED :: 1;
FC_END :: 5;
wuffs :: #library,no_dll "../../build/fc_vendor";
fc_inflate_state_size :: () -> u64 #foreign wuffs;
fc_inflate_init :: (state: *void, kind: s32) -> s32 #foreign wuffs;
fc_inflate_step :: (state: *void, src: *u8, src_len: u64, dst: *u8, dst_len: u64, consumed: *u64, produced: *u64) -> s32 #foreign wuffs;
