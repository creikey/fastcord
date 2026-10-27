Error :: enum u8 {
	None;
	Truncated;
	Corrupt;
	Output_Too_Large;
	Out_Of_Memory;
}
#scope_module
	BrotliDecoderCreateInstance :: (alloc: (opaque: *void, size: u64) -> *void #c_call, free: (opaque: *void, address: *void) #c_call, opaque: *void) -> *void #foreign lib;
	BrotliDecoderDestroyInstance :: (state: *void) #foreign lib;
	BrotliDecoderDecompressStream :: (state: *void, avail_in: *u64, next_in: **u8, avail_out: *u64, next_out: **u8, total_out: *u64) -> s32 #foreign lib;

c_alloc :: (_: *void, size: u64) -> *void #c_call {
	__ctx1: #Context; push_context,defer_pop __ctx1;
	p, _ := mem.alloc(cast(int)(size), 16, context.default_allocator);
	return p;
}

c_free :: (_: *void, address: *void) #c_call {
	__ctx2: #Context; push_context,defer_pop __ctx2;
	mem.free(address, context.default_allocator);
}
#scope_export

// Decompress one whole stream; bytes after its end are an error.
decompress :: (input: []u8, allocator := context.allocator, max_out := 256 << 20) -> []u8, Error {
	st := BrotliDecoderCreateInstance(c_alloc, c_free, null);
	if st == null { return .{}, .Out_Of_Memory; }
	defer BrotliDecoderDestroyInstance(st);
	out := make_dynamic(u8, 0, 0, allocator);
	next_in := raw_data(input);
	avail_in := cast(u64)(len(input));
	err := Error.None;
	while true {
		start := len(out);
		room := min(max(4096, cap(out) - start), max_out + 1 - start);
		resize(*out, start + room);
		next_out := raw_data(sub_from(out, start));
		avail_out := cast(u64)(room);
		r := BrotliDecoderDecompressStream(st, *avail_in, *next_in, *avail_out, *next_out, null);
		resize(*out, start + room - cast(int)(avail_out));
		if len(out) > max_out {
			err = .Output_Too_Large;
		} else if r == 0 {
			err = .Corrupt;
		} else if r == 1 {
			if avail_in != 0 { err = .Corrupt; }
		} else if r == 2 {
			err = .Truncated;
		} else {
			continue;
		}
		break;
	}
	if err != .None {
		delete(out);
		return .{}, err;
	}
	return view(out), .None;
}

