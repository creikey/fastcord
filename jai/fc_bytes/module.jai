#import "Basic";
#import "fc";
Buffer :: struct { buf: [..]u8; }
buffer_init_allocator :: (b: *Buffer, len: int, cap: int, allocator := context.allocator) { b.buf.allocator = allocator; array_reserve(*b.buf, cap); b.buf.count = len; }
buffer_write :: (b: *Buffer, p: []u8) -> int, *void { append(*b.buf, ..p); return p.count, null; }
buffer_write_string :: (b: *Buffer, s: string) -> int, *void { append(*b.buf, s); return s.count, null; }
buffer_write_byte :: (b: *Buffer, c: u8) -> *void { array_add(*b.buf, c); return null; }
buffer_to_bytes :: (b: *Buffer) -> []u8 { return b.buf; }
buffer_length :: (b: *Buffer) -> int { return b.buf.count; }
buffer_reset :: (b: *Buffer) { b.buf.count = 0; }
buffer_destroy :: (b: *Buffer) { array_free(b.buf); b.buf = .[]; }
