// Brotli (RFC 7932) through the vendored reference decoder (vendor/brotli). One-shot only.
#import "Basic";

Error :: enum u8 { None; Truncated; Corrupt; Output_Too_Large; Out_Of_Memory; }

// decompress decodes one whole stream into context.allocator; bytes after its end are an error.
decompress :: (input: []u8, max_out := 256 << 20) -> []u8, Error {
    st := BrotliDecoderCreateInstance(null, null, null);
    if !st return .[], .Out_Of_Memory;
    defer BrotliDecoderDestroyInstance(st);
    out: [..]u8;
    next_in := input.data;
    avail_in := cast(u64) input.count;
    err := Error.None;
    while true {
        start := out.count;
        if out.allocated - start < 4096 array_reserve(*out, max(out.allocated * 2, start + 4096));
        room := min(out.allocated - start, max_out + 1 - start);
        next_out := out.data + start;
        avail_out := cast(u64) room;
        r := BrotliDecoderDecompressStream(st, *avail_in, *next_in, *avail_out, *next_out, null);
        out.count = start + room - cast(int) avail_out;
        if out.count > max_out        err = .Output_Too_Large;
        else if r == RESULT_ERROR     err = .Corrupt;
        else if r == RESULT_SUCCESS { if avail_in err = .Corrupt; }
        else if r == RESULT_NEEDS_MORE_INPUT err = .Truncated;
        else continue;  // needs more output
        break;
    }
    if err != .None { array_free(out); return .[], err; }
    return out, .None;
}

#scope_file
RESULT_ERROR :: 0;
RESULT_SUCCESS :: 1;
RESULT_NEEDS_MORE_INPUT :: 2;
lib :: #library,no_dll "../../build/fc_vendor";
BrotliDecoderCreateInstance :: (alloc: *void, free: *void, opaque: *void) -> *void #foreign lib;
BrotliDecoderDestroyInstance :: (state: *void) #foreign lib;
BrotliDecoderDecompressStream :: (state: *void, avail_in: *u64, next_in: **u8, avail_out: *u64, next_out: **u8, total_out: *u64) -> s32 #foreign lib;
