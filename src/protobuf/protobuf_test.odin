package protobuf

import "core:testing"

@(test)
test_roundtrip :: proc(t: ^testing.T) {
	inner: Writer
	defer delete(inner.buf)
	write_string(&inner, 1, "dark")
	write_uint(&inner, 2, 300)
	w: Writer
	defer delete(w.buf)
	write_uint(&w, 1, 7)
	write_bytes(&w, 5, inner.buf[:])
	f, ok := find_path(w.buf[:], 5, 2)
	testing.expect(t, ok)
	testing.expect_value(t, f.value, 300)
	s, ok2 := find_path(w.buf[:], 5, 1)
	testing.expect(t, ok2)
	testing.expect_value(t, string(s.bytes), "dark")
	_, ok3 := find(w.buf[:3], 5) // truncated
	testing.expect(t, !ok3)
}
