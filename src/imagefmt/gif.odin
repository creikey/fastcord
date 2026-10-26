package imagefmt

// GIF 87a/89a with browser-style compositing: canvas starts transparent,
// disposal 2 clears the frame rect to transparent, 3 restores the previous
// canvas. NETSCAPE2.0 loop count n means n repeats (n+1 plays); 0 = forever.

import "core:mem"

@(private)
gif_lzw :: proc(src: []byte, min_size: u32, out: []u8) -> int #no_bounds_check {
	prefix: [4096]u16
	suffix: [4096]u8
	length: [4096]u16
	first: [4096]u8
	clear_code := u32(1) << min_size
	eoi := clear_code + 1
	for i in 0 ..< clear_code {
		suffix[i] = u8(i)
		first[i] = u8(i)
		length[i] = 1
	}
	code_size := min_size + 1
	next := clear_code + 2
	old := ~u32(0)
	bits: u32
	nbits: u32
	sp := 0
	pos := 0
	n := len(out)
	for pos < n {
		for nbits < code_size {
			if sp >= len(src) do return pos
			bits |= u32(src[sp]) << nbits
			sp += 1
			nbits += 8
		}
		code := bits & ((1 << code_size) - 1)
		bits >>= code_size
		nbits -= code_size
		if code == clear_code {
			code_size = min_size + 1
			next = clear_code + 2
			old = ~u32(0)
			continue
		}
		if code == eoi do break
		if old == ~u32(0) {
			if code >= clear_code do return pos
			out[pos] = u8(code)
			pos += 1
			old = code
			continue
		}
		c := code
		fc: u8
		if code < next {
			fc = first[code]
		} else if code == next {
			fc = first[old]
			c = old
		} else {
			return pos
		}
		// emit string(c) (+ fc when code == next)
		l := int(length[c])
		end := pos + l
		k := c
		for i := end - 1; i >= pos; i -= 1 {
			if i < n do out[i] = suffix[k]
			k = u32(prefix[k])
		}
		pos = end
		if code == next {
			if pos < n do out[pos] = fc
			pos += 1
		}
		if next < 4096 {
			prefix[next] = u16(old)
			suffix[next] = fc
			first[next] = first[old]
			length[next] = length[old] + 1
			next += 1
			if next == 1 << code_size && code_size < 12 do code_size += 1
		}
		old = code
	}
	return min(pos, n)
}

@(private)
gif_skip_blocks :: proc(data: []byte, p: ^int) -> bool {
	for {
		if p^ >= len(data) do return false
		n := int(data[p^])
		p^ += 1
		if n == 0 do return true
		p^ += n
	}
}

@(private)
gif_decode :: proc(c: ^Decode_Ctx, data: []byte, img: ^Image) -> Error {
	if len(data) < 13 do return .Truncated
	cw := le16i(data[6:])
	ch := le16i(data[8:])
	flags := data[10]
	p := 13
	gct: []byte
	if flags & 0x80 != 0 {
		n := 3 << ((flags & 7) + 1)
		if p + n > len(data) do return .Truncated
		gct = data[p:p + n]
		p += n
	}
	img.loop_count = 1
	canvas: []u8
	saved: []u8
	defer delete(canvas, c.allocator)
	defer delete(saved, c.allocator)
	comp := make([dynamic]byte, c.allocator)
	defer delete(comp)
	idx: []u8
	defer delete(idx, c.allocator)

	// graphic control state for the next image
	g_dispose: u8
	g_delay := 0
	g_transp := -1
	// previous frame disposal
	prev_dispose: u8
	prev_rect: [4]int

	for p < len(data) {
		b := data[p]
		p += 1
		switch b {
		case 0x21:
			if p >= len(data) do return len(c.frames) > 0 ? .None : .Truncated
			label := data[p]
			p += 1
			if label == 0xF9 && p + 5 < len(data) && data[p] == 4 {
				pk := data[p + 1]
				g_dispose = (pk >> 2) & 7
				g_delay = le16i(data[p + 2:]) * 10
				g_transp = pk & 1 == 1 ? int(data[p + 4]) : -1
				p += 5
			} else if label == 0xFF && p + 12 <= len(data) && data[p] == 11 && (string(data[p + 1:p + 12]) == "NETSCAPE2.0" || string(data[p + 1:p + 12]) == "ANIMEXTS1.0") {
				p += 12
				if p + 4 <= len(data) && data[p] >= 3 && data[p + 1] == 1 {
					n := le16i(data[p + 2:])
					img.loop_count = n == 0 ? 0 : n + 1
				}
			}
			if !gif_skip_blocks(data, &p) do return len(c.frames) > 0 ? .None : .Truncated
		case 0x2C:
			if p + 9 > len(data) do return len(c.frames) > 0 ? .None : .Truncated
			fx, fy := le16i(data[p:]), le16i(data[p + 2:])
			fw, fh := le16i(data[p + 4:]), le16i(data[p + 6:])
			ff := data[p + 8]
			p += 9
			pal := gct
			if ff & 0x80 != 0 {
				n := 3 << ((ff & 7) + 1)
				if p + n > len(data) do return len(c.frames) > 0 ? .None : .Truncated
				pal = data[p:p + n]
				p += n
			}
			if p >= len(data) do return len(c.frames) > 0 ? .None : .Truncated
			min_size := u32(data[p])
			p += 1
			clear(&comp)
			for p < len(data) {
				n := int(data[p])
				p += 1
				if n == 0 do break
				e := min(p + n, len(data))
				append(&comp, ..data[p:e])
				p = e
			}
			if canvas == nil {
				// a missing/too-small logical screen grows to fit the first frame
				if cw < fx + fw || ch < fy + fh {
					cw = max(cw, fx + fw)
					ch = max(ch, fy + fh)
				}
				check_size(c, cw, ch) or_return
				img.width, img.height = cw, ch
				canvas = alloc_pixels(c, cw, ch) or_return
			} else {
				// dispose the previous frame
				switch prev_dispose {
				case 2:
					for y in prev_rect[1] ..< prev_rect[3] do mem.zero_slice(canvas[(y * cw + prev_rect[0]) * 4:][:(prev_rect[2] - prev_rect[0]) * 4])
				case 3:
					if saved != nil do copy(canvas, saved)
				}
			}
			if g_dispose == 3 {
				if saved == nil do saved = alloc_pixels(c, cw, ch) or_return
				copy(saved, canvas)
			}
			if min_size < 1 || min_size > 11 || fw * fh > c.max_pixels do return len(c.frames) > 0 ? .None : .Corrupt
			if len(idx) < fw * fh {
				delete(idx, c.allocator)
				idx = make([]u8, fw * fh, c.allocator)
			}
			got := gif_lzw(comp[:], min_size, idx[:fw * fh])
			interlaced := ff & 0x40 != 0
			x0, y0 := fx, fy
			x1, y1 := min(fx + fw, cw), min(fy + fh, ch)
			npal := len(pal) / 3
			for r in 0 ..< fh {
				if r * fw >= got do break
				y := r
				if interlaced {
					// pass 1: every 8th from 0, pass 2: every 8th from 4, pass 3: every 4th from 2, pass 4: odd
					n1 := (fh + 7) / 8
					n2 := (fh + 3) / 8
					n3 := (fh + 1) / 4
					if r < n1 {
						y = r * 8
					} else if r < n1 + n2 {
						y = (r - n1) * 8 + 4
					} else if r < n1 + n2 + n3 {
						y = (r - n1 - n2) * 4 + 2
					} else {
						y = (r - n1 - n2 - n3) * 2 + 1
					}
				}
				cy := fy + y
				if cy < y0 || cy >= y1 do continue
				row := idx[r * fw:]
				lim := min(fw, got - r * fw)
				for x in 0 ..< lim {
					cx := fx + x
					if cx < x0 || cx >= x1 do continue
					v := int(row[x])
					if v == g_transp do continue
					o := canvas[(cy * cw + cx) * 4:]
					if v < npal {
						o[0], o[1], o[2] = pal[v * 3], pal[v * 3 + 1], pal[v * 3 + 2]
					} else {
						o[0], o[1], o[2] = 0, 0, 0
					}
					o[3] = 255
				}
			}
			push_frame(c, canvas, g_delay) or_return
			prev_dispose = g_dispose
			prev_rect = {clamp(x0, 0, cw), clamp(y0, 0, ch), clamp(x1, 0, cw), clamp(y1, 0, ch)}
			g_dispose, g_delay, g_transp = 0, 0, -1
			if c.first_only do return .None
		case 0x3B:
			return .None
		case:
			return len(c.frames) > 0 ? .None : .Corrupt
		}
	}
	return .None
}
