// Package zstd decodes Zstandard (RFC 8878) with the reference decoder, vendored in vendor/zstd
// and compiled into build/fc_zstd.obj by build.sh / build.bat. Its memory comes from the Odin
// allocator passed in.
//
// Two entry points:
//   - decompress: whole input (one or more frames, skippable frames allowed).
//   - Stream_Decoder: feed bytes as they arrive (Discord `compress=zstd-stream`
//     sends one endless frame split across WebSocket messages). Input may be
//     split at any byte; history, entropy tables and repeat offsets persist.
//
// Not supported: dictionaries (frames with a non-zero Dictionary_ID are rejected).
package zstd

import "base:runtime"
import "core:mem"

when ODIN_OS == .Windows {
	foreign import lib "../../build/fc_zstd.obj"
} else {
	foreign import lib "../../build/fc_zstd.o"
}

Error :: enum u8 {
	None,
	Truncated, // decompress: input ended inside a frame
	Bad_Magic,
	Bad_Frame_Header,
	Window_Too_Large,
	Dictionary_Unsupported,
	Corrupt,
	Checksum_Mismatch,
	Size_Mismatch, // Frame_Content_Size disagrees with decoded size
	Output_Too_Large,
	Out_Of_Memory,
}

// Largest window accepted by default: 128 MB covers `zstd --long` (windowLog 27).
// Discord's gateway uses 8 MB or less. Memory is only used as data arrives.
DEFAULT_MAX_WINDOW :: 1 << 27

@(private)
In_Buffer :: struct {
	src:  rawptr,
	size: uint,
	pos:  uint,
}

@(private)
Out_Buffer :: struct {
	dst:  rawptr,
	size: uint,
	pos:  uint,
}

@(private)
Custom_Mem :: struct {
	alloc:  proc "c" (opaque: rawptr, size: uint) -> rawptr,
	free:   proc "c" (opaque: rawptr, address: rawptr),
	opaque: rawptr,
}

@(private)
D_WINDOW_LOG_MAX :: 100

@(default_calling_convention = "c")
@(private)
foreign lib {
	ZSTD_createDCtx_advanced :: proc(mem: Custom_Mem) -> rawptr ---
	ZSTD_freeDCtx :: proc(dctx: rawptr) -> uint ---
	ZSTD_DCtx_setParameter :: proc(dctx: rawptr, param: i32, value: i32) -> uint ---
	ZSTD_decompressStream :: proc(dctx: rawptr, output: ^Out_Buffer, input: ^In_Buffer) -> uint ---
	ZSTD_isError :: proc(code: uint) -> u32 ---
	ZSTD_getErrorCode :: proc(code: uint) -> i32 ---
}

Stream_Decoder :: struct {
	dctx:     rawptr,
	mem:      ^mem.Allocator, // boxed so its address, which the C side keeps, survives moves
	err:      Error, // sticky
	boundary: bool, // the last call ended a frame with nothing left over
}

@(private)
c_alloc :: proc "c" (opaque: rawptr, size: uint) -> rawptr {
	context = runtime.default_context()
	p, _ := mem.alloc(int(size), 16, (^mem.Allocator)(opaque)^)
	return p
}

@(private)
c_free :: proc "c" (opaque: rawptr, address: rawptr) {
	context = runtime.default_context()
	mem.free(address, (^mem.Allocator)(opaque)^)
}

@(private)
to_error :: proc(code: uint) -> Error {
	switch ZSTD_getErrorCode(code) {
	case 10: return .Bad_Magic // prefix_unknown
	case 12, 14: return .Bad_Frame_Header // version / frame parameter unsupported
	case 16: return .Window_Too_Large
	case 22: return .Checksum_Mismatch
	case 30, 32: return .Dictionary_Unsupported
	case 64: return .Out_Of_Memory
	case 72: return .Size_Mismatch // srcSize_wrong: content size disagrees
	}
	return .Corrupt
}

// ---------------------------------------------------------------------------
// Public API

stream_init :: proc(d: ^Stream_Decoder, allocator := context.allocator, max_window := DEFAULT_MAX_WINDOW) {
	d^ = {boundary = true}
	d.mem = new_clone(allocator, allocator)
	d.dctx = ZSTD_createDCtx_advanced({c_alloc, c_free, d.mem})
	if d.dctx == nil {
		d.err = .Out_Of_Memory
		return
	}
	log: i32 = 10
	for (1 << uint(log)) < max_window do log += 1
	ZSTD_DCtx_setParameter(d.dctx, D_WINDOW_LOG_MAX, log)
}

stream_destroy :: proc(d: ^Stream_Decoder) {
	if d.dctx != nil do ZSTD_freeDCtx(d.dctx)
	if d.mem != nil do free(d.mem, d.mem^)
	d^ = {}
}

// Feed the next chunk; appends all output decodable so far to out.
// Errors are sticky: after one, the decoder must be destroyed and re-initialised.
stream_decode :: proc(d: ^Stream_Decoder, input: []byte, out: ^[dynamic]byte) -> Error {
	if d.err != .None do return d.err
	d.err = run(d.dctx, input, out, max(int))
	return d.err
}

// True when the decoder sits between frames with nothing buffered.
stream_at_frame_boundary :: proc(d: ^Stream_Decoder) -> bool {
	return d.boundary
}

// Decompress whole frames (any number, skippable frames allowed).
decompress :: proc(input: []byte, allocator := context.allocator, max_out := 1 << 30, max_window := DEFAULT_MAX_WINDOW) -> ([]byte, Error) {
	d: Stream_Decoder
	stream_init(&d, runtime.heap_allocator(), max_window)
	defer stream_destroy(&d)
	if d.err != .None do return nil, d.err
	out := make([dynamic]byte, allocator)
	err := run(d.dctx, input, &out, max_out, &d.boundary)
	if err == .None && (!d.boundary || len(input) == 0) do err = .Truncated
	if err != .None {
		delete(out)
		return nil, err
	}
	return out[:], .None
}

// Decodes all of input, appending to out. boundary is set when the input ended exactly at the end of
// a frame (the decoder's "frame complete and flushed" return of 0).
@(private)
run :: proc(dctx: rawptr, input: []byte, out: ^[dynamic]byte, max_out: int, boundary: ^bool = nil) -> Error {
	in_buf := In_Buffer{raw_data(input), uint(len(input)), 0}
	ret: uint = 1
	for {
		start := len(out)
		room := max(4096, cap(out) - start)
		if start + room > max_out {
			room = max_out - start
			if room <= 0 {
				// Full: one probe byte tells a finished stream from one that would overflow.
				if in_buf.pos == in_buf.size && ret == 0 do break
				room = 1
			}
		}
		if resize(out, start + room) != nil do return .Out_Of_Memory
		out_buf := Out_Buffer{raw_data(out[start:]), uint(room), 0}
		ret = ZSTD_decompressStream(dctx, &out_buf, &in_buf)
		resize(out, start + int(out_buf.pos))
		if ZSTD_isError(ret) != 0 do return to_error(ret)
		if len(out) > max_out do return .Output_Too_Large
		// Done once all input is consumed and the output wasn't the limit on this call.
		if in_buf.pos == in_buf.size && out_buf.pos < out_buf.size do break
	}
	if boundary != nil do boundary^ = ret == 0
	return .None
}
