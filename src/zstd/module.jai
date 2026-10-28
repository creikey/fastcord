// Zstandard (RFC 8878) through the vendored reference decoder (vendor/zstd/fc_zstd.c).
//   decompress: a whole input (one or more frames, skippable frames allowed).
//   Stream_Decoder: bytes as they arrive (Discord's `compress=zstd-stream` sends one endless frame split
//   across WebSocket messages); history, entropy tables and repeat offsets persist between feeds.
// Dictionaries are not supported.
#import "Basic";
#import "Math";

Error :: enum u8 {
    None;
    Truncated;        // decompress: input ended inside a frame
    Bad_Magic;
    Bad_Frame_Header;
    Window_Too_Large;
    Dictionary_Unsupported;
    Corrupt;
    Checksum_Mismatch;
    Size_Mismatch;    // Frame_Content_Size disagrees with decoded size
    Output_Too_Large;
    Out_Of_Memory;
}

// Largest window accepted by default: 128 MB covers `zstd --long` (windowLog 27).
// Discord's gateway uses 8 MB or less. Memory is only used as data arrives.
DEFAULT_MAX_WINDOW :: 1 << 27;

Stream_Decoder :: struct {
    dctx: *void;
    err: Error;  // sticky
}

stream_init :: (d: *Stream_Decoder, max_window := DEFAULT_MAX_WINDOW) {
    d.* = .{dctx = ZSTD_createDCtx()};
    if !d.dctx { d.err = .Out_Of_Memory; return; }
    log: s32 = 10;
    while (1 << log) < max_window log += 1;
    ZSTD_DCtx_setParameter(d.dctx, D_WINDOW_LOG_MAX, log);
}

stream_destroy :: (d: *Stream_Decoder) {
    if d.dctx ZSTD_freeDCtx(d.dctx);
    d.* = .{};
}

// stream_decode feeds the next chunk, appending all output decodable so far to out.
// Errors are sticky: after one, the decoder must be destroyed and re-initialised.
// out may hold at most max_out bytes, counting what was in it already; past that, Output_Too_Large.
stream_decode :: (d: *Stream_Decoder, input: []u8, out: *[..]u8, max_out := S64_MAX) -> Error {
    if d.err != .None return d.err;
    d.err = run(d.dctx, input, out, max_out);
    return d.err;
}

// decompress decodes whole frames into context.allocator.
decompress :: (input: []u8, max_out := 1 << 30, max_window := DEFAULT_MAX_WINDOW) -> []u8, Error {
    d: Stream_Decoder;
    stream_init(*d, max_window);
    defer stream_destroy(*d);
    if d.err != .None return .[], d.err;
    out: [..]u8;
    boundary: bool;
    err := run(d.dctx, input, *out, max_out, *boundary);
    if err == .None && (!boundary || !input.count) err = .Truncated;
    if err != .None { array_free(out); return .[], err; }
    return out, .None;
}

#scope_file

// run decodes all of input, appending to out. boundary is set when the input ended exactly at the end of
// a frame (the decoder's "frame complete and flushed" return of 0).
run :: (dctx: *void, input: []u8, out: *[..]u8, max_out: int, boundary: *bool = null) -> Error {
    in_buf := In_Buffer.{input.data, xx input.count, 0};
    ret: u64 = 1;
    while true {
        start := out.count;
        if out.allocated - start < 4096 array_reserve(out, max(out.allocated * 2, start + 4096));
        room := out.allocated - start;
        if start + room > max_out {
            room = max_out - start;
            if room <= 0 {
                // Full: one probe byte tells a finished stream from one that would overflow.
                if in_buf.pos == in_buf.size && ret == 0 break;
                room = 1;
            }
        }
        out_buf := Out_Buffer.{out.data + start, xx room, 0};
        ret = ZSTD_decompressStream(dctx, *out_buf, *in_buf);
        out.count = start + cast(int) out_buf.pos;
        if ZSTD_isError(ret) return to_error(ret);
        if out.count > max_out return .Output_Too_Large;
        // Done once all input is consumed and the output wasn't the limit on this call.
        if in_buf.pos == in_buf.size && out_buf.pos < out_buf.size break;
    }
    if boundary boundary.* = ret == 0;
    return .None;
}

to_error :: (code: u64) -> Error {
    if ZSTD_getErrorCode(code) == {
        case 10;      return .Bad_Magic;  // prefix_unknown
        case 12; #through;
        case 14;      return .Bad_Frame_Header;  // version / frame parameter unsupported
        case 16;      return .Window_Too_Large;
        case 22;      return .Checksum_Mismatch;
        case 30; #through;
        case 32;      return .Dictionary_Unsupported;
        case 64;      return .Out_Of_Memory;
        case 72;      return .Size_Mismatch;  // srcSize_wrong: content size disagrees
    }
    return .Corrupt;
}

In_Buffer :: struct { src: *void; size: u64; pos: u64; }
Out_Buffer :: struct { dst: *void; size: u64; pos: u64; }
D_WINDOW_LOG_MAX :: 100;
lib :: #library,no_dll "../../build/fc_vendor";
ZSTD_createDCtx :: () -> *void #foreign lib;
ZSTD_freeDCtx :: (dctx: *void) -> u64 #foreign lib;
ZSTD_DCtx_setParameter :: (dctx: *void, param: s32, value: s32) -> u64 #foreign lib;
ZSTD_decompressStream :: (dctx: *void, output: *Out_Buffer, input: *In_Buffer) -> u64 #foreign lib;
ZSTD_isError :: (code: u64) -> u32 #foreign lib;
ZSTD_getErrorCode :: (code: u64) -> s32 #foreign lib;
