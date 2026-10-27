// Package brotli decodes Brotli (RFC 7932) with the reference decoder, vendored in vendor/brotli
// and compiled into build/fc_brotli.obj by build.sh / build.bat. One-shot only (whole input in
// memory); the decoder's own memory comes from the heap allocator.
package brotli

import "base:runtime"
import "core:mem"

when ODIN_OS == .Windows {
	foreign import lib "../../build/fc_brotli.obj"
} else {
	foreign import lib "../../build/fc_brotli.o"
}

Error :: enum u8 {
	None,
	Truncated,
	Corrupt,
	Output_Too_Large,
	Out_Of_Memory,
}

@(default_calling_convention = "c")
@(private)
foreign lib {
	BrotliDecoderCreateInstance :: proc(alloc: proc "c" (opaque: rawptr, size: uint) -> rawptr, free: proc "c" (opaque, address: rawptr), opaque: rawptr) -> rawptr ---
	BrotliDecoderDestroyInstance :: proc(state: rawptr) ---
	BrotliDecoderDecompressStream :: proc(state: rawptr, avail_in: ^uint, next_in: ^[^]u8, avail_out: ^uint, next_out: ^[^]u8, total_out: ^uint) -> i32 ---
}

@(private)
c_alloc :: proc "c" (_: rawptr, size: uint) -> rawptr {
	context = runtime.default_context()
	p, _ := mem.alloc(int(size), 16, runtime.heap_allocator())
	return p
}

@(private)
c_free :: proc "c" (_: rawptr, address: rawptr) {
	context = runtime.default_context()
	mem.free(address, runtime.heap_allocator())
}

// Decompress one whole stream; bytes after its end are an error.
decompress :: proc(input: []byte, allocator := context.allocator, max_out := 256 << 20) -> ([]byte, Error) {
	st := BrotliDecoderCreateInstance(c_alloc, c_free, nil)
	if st == nil do return nil, .Out_Of_Memory
	defer BrotliDecoderDestroyInstance(st)
	out := make([dynamic]byte, allocator)
	next_in := raw_data(input)
	avail_in := uint(len(input))
	err := Error.None
	for {
		start := len(out)
		room := min(max(4096, cap(out) - start), max_out + 1 - start)
		if resize(&out, start + room) != nil {
			err = .Out_Of_Memory
			break
		}
		next_out := raw_data(out[start:])
		avail_out := uint(room)
		r := BrotliDecoderDecompressStream(st, &avail_in, &next_in, &avail_out, &next_out, nil)
		resize(&out, start + room - int(avail_out))
		if len(out) > max_out {
			err = .Output_Too_Large
		} else if r == 0 {
			err = .Corrupt
		} else if r == 1 {
			if avail_in != 0 do err = .Corrupt
		} else if r == 2 {
			err = .Truncated
		} else {
			continue
		}
		break
	}
	if err != .None {
		delete(out)
		return nil, err
	}
	return out[:], .None
}
