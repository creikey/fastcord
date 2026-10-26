package quic

// Byte-range bookkeeping shared by CRYPTO and STREAM data.

Range :: struct {
	lo, hi: u64, // [lo, hi)
}

// Range_Set is a sorted list of disjoint, non-adjacent ranges.
Range_Set :: [dynamic]Range

rs_add :: proc(s: ^Range_Set, lo, hi: u64) {
	if lo >= hi do return
	nlo, nhi := lo, hi
	i := 0
	for i < len(s) && s[i].hi < nlo do i += 1
	j := i
	for j < len(s) && s[j].lo <= nhi {
		nlo = min(nlo, s[j].lo)
		nhi = max(nhi, s[j].hi)
		j += 1
	}
	if j > i do remove_range(s, i, j)
	inject_at(s, i, Range{nlo, nhi})
}

rs_remove :: proc(s: ^Range_Set, lo, hi: u64) {
	if lo >= hi do return
	i := 0
	for i < len(s) {
		r := s[i]
		if r.hi <= lo || r.lo >= hi {
			i += 1
			continue
		}
		ordered_remove(s, i)
		if r.lo < lo {
			inject_at(s, i, Range{r.lo, lo})
			i += 1
		}
		if r.hi > hi {
			inject_at(s, i, Range{hi, r.hi})
			i += 1
		}
	}
}

rs_contains :: proc(s: ^Range_Set, lo, hi: u64) -> bool {
	for r in s do if r.lo <= lo && hi <= r.hi do return true
	return false
}

// Send_Buf holds outgoing data until acknowledged. Offsets are absolute.
Send_Buf :: struct {
	data:        [dynamic]byte, // bytes [base, end)
	base:        u64,
	end:         u64,
	pending:     Range_Set, // still to (re)transmit
	acked:       Range_Set,
	fin:         bool, // end is the final size
	fin_pending: bool,
	fin_acked:   bool,
}

sb_write :: proc(b: ^Send_Buf, data: []byte) {
	if len(data) == 0 do return
	append(&b.data, ..data)
	rs_add(&b.pending, b.end, b.end + u64(len(data)))
	b.end += u64(len(data))
}

sb_finish :: proc(b: ^Send_Buf) {
	if b.fin do return
	b.fin = true
	b.fin_pending = true
}

sb_has_pending :: proc(b: ^Send_Buf) -> bool {return len(b.pending) > 0 || b.fin_pending}

// sb_peek returns the next chunk to send (at most max_len bytes, below limit).
sb_peek :: proc(b: ^Send_Buf, max_len: int, limit: u64 = max(u64)) -> (off: u64, data: []byte, fin: bool) {
	if len(b.pending) == 0 {
		return b.end, nil, b.fin_pending
	}
	r := b.pending[0]
	hi := min(r.hi, r.lo + u64(max(max_len, 0)), max(limit, r.lo))
	data = b.data[r.lo - b.base:hi - b.base]
	fin = b.fin_pending && hi == b.end && len(b.pending) == 1
	return r.lo, data, fin
}

sb_consume :: proc(b: ^Send_Buf, off: u64, n: int, fin: bool) {
	rs_remove(&b.pending, off, off + u64(n))
	if fin do b.fin_pending = false
}

sb_on_ack :: proc(b: ^Send_Buf, lo, hi: u64, fin: bool) {
	rs_add(&b.acked, lo, hi)
	if fin do b.fin_acked = true
	// Release the acknowledged prefix.
	if len(b.acked) > 0 && b.acked[0].lo <= b.base && b.acked[0].hi > b.base {
		cut := b.acked[0].hi - b.base
		remove_range(&b.data, 0, int(cut))
		b.base += cut
	}
}

sb_on_lost :: proc(b: ^Send_Buf, lo, hi: u64, fin: bool) {
	l := max(lo, b.base)
	if l < hi {
		rs_add(&b.pending, l, hi)
		for a in b.acked do rs_remove(&b.pending, a.lo, a.hi)
	}
	if fin && !b.fin_acked do b.fin_pending = true
}

sb_all_acked :: proc(b: ^Send_Buf) -> bool {
	return b.base == b.end && (!b.fin || b.fin_acked)
}

sb_destroy :: proc(b: ^Send_Buf) {
	delete(b.data)
	delete(b.pending)
	delete(b.acked)
}

// Recv_Buf reassembles incoming data. buf holds bytes [read_off, read_off+len(buf)).
Recv_Buf :: struct {
	buf:      [dynamic]byte,
	read_off: u64,
	have:     Range_Set,
	highest:  u64, // highest offset received (for flow control)
}

// rb_insert stores data at off; duplicates are ignored.
rb_insert :: proc(b: ^Recv_Buf, off: u64, data: []byte) {
	end := off + u64(len(data))
	b.highest = max(b.highest, end)
	if end <= b.read_off do return
	src := data
	o := off
	if o < b.read_off {
		src = src[b.read_off - o:]
		o = b.read_off
	}
	need := int(end - b.read_off)
	if need > len(b.buf) do resize(&b.buf, need)
	copy(b.buf[o - b.read_off:], src)
	rs_add(&b.have, o, end)
}

// rb_readable is the contiguous data available from read_off.
rb_readable :: proc(b: ^Recv_Buf) -> []byte {
	if len(b.have) == 0 || b.have[0].lo > b.read_off do return nil
	return b.buf[:b.have[0].hi - b.read_off]
}

rb_consume :: proc(b: ^Recv_Buf, n: int) {
	remove_range(&b.buf, 0, n)
	b.read_off += u64(n)
	rs_remove(&b.have, 0, b.read_off)
}

rb_destroy :: proc(b: ^Recv_Buf) {
	delete(b.buf)
	delete(b.have)
}
