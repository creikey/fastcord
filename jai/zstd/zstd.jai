#if OS == .WINDOWS {
} else {
}

Error :: enum u8 {
	None;
	Truncated; // decompress: input ended inside a frame
	Bad_Magic;
	Bad_Frame_Header;
	Window_Too_Large;
	Dictionary_Unsupported;
	Corrupt;
	Checksum_Mismatch;
	Size_Mismatch; // Frame_Content_Size disagrees with decoded size
	Output_Too_Large;
	Out_Of_Memory;
}

// Largest window accepted by default: 128 MB covers `zstd --long` (windowLog 27).
// Discord's gateway uses 8 MB or less. Memory is only used as data arrives.
DEFAULT_MAX_WINDOW :: 1 << 27;
#scope_module

In_Buffer :: struct {
	src: *void;
	size: u64;
	pos: u64;
}

Out_Buffer :: struct {
	dst: *void;
	size: u64;
	pos: u64;
}

Custom_Mem :: struct {
	alloc: (opaque: *void, size: u64) -> *void #c_call;
	free: (opaque: *void, address: *void) #c_call;
	opaque: *void;
}

D_WINDOW_LOG_MAX :: 100;
	ZSTD_createDCtx_advanced :: (mem: Custom_Mem) -> *void #foreign lib;
	ZSTD_freeDCtx :: (dctx: *void) -> u64 #foreign lib;
	ZSTD_DCtx_setParameter :: (dctx: *void, param: s32, value: s32) -> u64 #foreign lib;
	ZSTD_decompressStream :: (dctx: *void, output: *Out_Buffer, input: *In_Buffer) -> u64 #foreign lib;
	ZSTD_isError :: (code: u64) -> u32 #foreign lib;
	ZSTD_getErrorCode :: (code: u64) -> s32 #foreign lib;
#scope_export

Stream_Decoder :: struct {
	dctx: *void;
	mem: *Allocator; // boxed so its address, which the C side keeps, survives moves
	err: Error; // sticky
	boundary: bool; // the last call ended a frame with nothing left over
}
#scope_module

c_alloc :: (opaque: *void, size: u64) -> *void #c_call {
	__ctx1: #Context; push_context,defer_pop __ctx1;
	p, _ := mem.alloc(cast(int)(size), 16, (cast(*Allocator)(opaque)).*);
	return p;
}

c_free :: (opaque: *void, address: *void) #c_call {
	__ctx2: #Context; push_context,defer_pop __ctx2;
	mem.free(address, (cast(*Allocator)(opaque)).*);
}

to_error :: (code: u64) -> Error {
	if ZSTD_getErrorCode(code) == {
	case 10; return .Bad_Magic; // prefix_unknown
	case 12; #through; case 14; return .Bad_Frame_Header; // version / frame parameter unsupported
	case 16; return .Window_Too_Large;
	case 22; return .Checksum_Mismatch;
	case 30; #through; case 32; return .Dictionary_Unsupported;
	case 64; return .Out_Of_Memory;
	case 72; return .Size_Mismatch; // srcSize_wrong: content size disagrees
	}
	return .Corrupt;
}
#scope_export

// ---------------------------------------------------------------------------
// Public API

stream_init :: (d: *Stream_Decoder, allocator := context.allocator, max_window := DEFAULT_MAX_WINDOW) {
	d.* = .{boundary = true};
	d.mem = new_clone(allocator, allocator);
	d.dctx = ZSTD_createDCtx_advanced(.{c_alloc, c_free, d.mem});
	if d.dctx == null {
		d.err = .Out_Of_Memory;
		return;
	}
	log: s32 = 10;
	while (1 << cast(u64)(log)) < max_window { log += 1; }
	ZSTD_DCtx_setParameter(d.dctx, D_WINDOW_LOG_MAX, log);
}

stream_destroy :: (d: *Stream_Decoder) {
	if d.dctx != null { ZSTD_freeDCtx(d.dctx); }
	if d.mem != null { free(d.mem, d.mem.*); }
	d.* = .{};
}

// Feed the next chunk; appends all output decodable so far to out.
// Errors are sticky: after one, the decoder must be destroyed and re-initialised.
stream_decode :: (d: *Stream_Decoder, input: []u8, out: *[..]u8) -> Error {
	if d.err != .None { return d.err; }
	d.err = run(d.dctx, input, out, S64_MAX);
	return d.err;
}

// True when the decoder sits between frames with nothing buffered.
stream_at_frame_boundary :: (d: *Stream_Decoder) -> bool {
	return d.boundary;
}

// Decompress whole frames (any number, skippable frames allowed).
decompress :: (input: []u8, allocator := context.allocator, max_out := 1 << 30, max_window := DEFAULT_MAX_WINDOW) -> []u8, Error {
	d: Stream_Decoder;
	stream_init(*d, context.default_allocator, max_window);
	defer stream_destroy(*d);
	if d.err != .None { return .{}, d.err; }
	out := make_dynamic(u8, 0, 0, allocator);
	err := run(d.dctx, input, *out, max_out, *d.boundary);
	if err == .None && (!d.boundary || len(input) == 0) { err = .Truncated; }
	if err != .None {
		delete(out);
		return .{}, err;
	}
	return view(out), .None;
}
#scope_module

// Decodes all of input, appending to out. boundary is set when the input ended exactly at the end of
// a frame (the decoder's "frame complete and flushed" return of 0).
run :: (dctx: *void, input: []u8, out: *[..]u8, max_out: int, boundary: *bool = null) -> Error {
	in_buf := In_Buffer.{raw_data(input), cast(u64)(len(input)), 0};
	ret: u64 = 1;
	while true {
		start := len(out);
		room := max(4096, cap(out) - start);
		if start + room > max_out {
			room = max_out - start;
			if room <= 0 {
				// Full: one probe byte tells a finished stream from one that would overflow.
				if in_buf.pos == in_buf.size && ret == 0 { break; }
				room = 1;
			}
		}
		if resize(out, start + room) != null { return .Out_Of_Memory; }
		out_buf := Out_Buffer.{raw_data(sub_from(out, start)), cast(u64)(room), 0};
		ret = ZSTD_decompressStream(dctx, *out_buf, *in_buf);
		resize(out, start + cast(int)(out_buf.pos));
		if ZSTD_isError(ret) != 0 { return to_error(ret); }
		if len(out) > max_out { return .Output_Too_Large; }
		// Done once all input is consumed and the output wasn't the limit on this call.
		if in_buf.pos == in_buf.size && out_buf.pos < out_buf.size { break; }
	}
	if boundary != null { boundary.* = ret == 0; }
	return .None;
}
#scope_export

