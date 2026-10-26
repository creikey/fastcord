package media

// ISO BMFF / QuickTime: progressive (moov + sample tables) and fragmented
// (moof/traf/trun) files. Top-level boxes are walked as they arrive.

@(private = "file")
Trex :: struct {
	track_id:                         u32,
	def_dur, def_size, def_flags:     u32,
}

@(private = "file")
Mp4 :: struct {
	trex:        [dynamic]Trex,
	frag_dts:    map[u32]i64, // track id -> next dts for fragments without tfdt
	elst_shift:  map[u32]i64, // track id -> media time of first edit (pts shift)
	have_moov:   bool,
}

@(private)
mp4_init :: proc(d: ^Demuxer) {
	d.format = .MP4
	m := new(Mp4)
	d.state = m
	d.scan_proc = mp4_scan
	d.free_proc = proc(d: ^Demuxer) {
		m := (^Mp4)(d.state)
		delete(m.trex)
		delete(m.frag_dts)
		delete(m.elst_shift)
		free(m)
	}
}

@(private = "file")
Box :: struct {
	type:   string, // 4 chars, points into header buffer copy
	start:  i64,
	hdr:    i64,
	size:   i64, // total, -1 = to end of file
}

@(private = "file")
type4 :: proc(b: []u8) -> [4]u8 {return {b[0], b[1], b[2], b[3]}}

@(private = "file")
mp4_scan :: proc(d: ^Demuxer) -> Scan_Status {
	m := (^Mp4)(d.state)
	avail, complete := source_extent(d.src)
	if d.scan_pos >= avail {
		if complete do return m.have_moov ? .Done : .Error
		return .Need_Data
	}
	if avail - d.scan_pos < 8 do return complete ? (m.have_moov ? .Done : .Error) : .Need_Data
	hb: [16]u8
	if read_full(d.src, d.scan_pos, hb[:8]) != .Ok do return .Need_Data
	size := i64(be32(hb[:]))
	t := type4(hb[4:])
	hdr: i64 = 8
	if size == 1 {
		if read_full(d.src, d.scan_pos + 8, hb[8:16]) != .Ok do return .Need_Data
		size = i64(be64(hb[8:]))
		hdr = 16
	} else if size == 0 {
		if !complete do return .Need_Data
		size = avail - d.scan_pos
	}
	if size < hdr do return .Error
	switch string(t[:]) {
	case "moov", "moof":
		if d.scan_pos + size > avail do return complete ? .Error : .Need_Data
		body := make([]u8, size - hdr)
		defer delete(body)
		if read_full(d.src, d.scan_pos + hdr, body) != .Ok do return .Need_Data
		if string(t[:]) == "moov" {
			parse_moov(d, m, body)
			m.have_moov = true
			d.ready = true
		} else {
			parse_moof(d, m, body, d.scan_pos)
		}
	}
	d.scan_pos += size
	return .Progress
}

// Iterate child boxes of a body buffer.
@(private = "file")
Child :: struct {
	type: string,
	body: []u8,
	off:  int, // offset of body within parent buffer
}

@(private = "file")
children :: proc(b: []u8, out: ^[dynamic]Child) {
	clear(out)
	i := 0
	for i + 8 <= len(b) {
		size := int(be32(b[i:]))
		hdr := 8
		if size == 1 {
			if i + 16 > len(b) do break
			size = int(be64(b[i + 8:]))
			hdr = 16
		} else if size == 0 {
			size = len(b) - i
		}
		if size < hdr || i + size > len(b) do break
		append(out, Child{string(b[i + 4:][:4]), b[i + hdr:i + size], i + hdr})
		i += size
	}
}

@(private = "file")
find :: proc(b: []u8, type: string) -> ([]u8, bool) {
	cs := make([dynamic]Child, context.temp_allocator)
	children(b, &cs)
	for c in cs do if c.type == type do return c.body, true
	return nil, false
}

@(private = "file")
find_path :: proc(b: []u8, path: ..string) -> ([]u8, bool) {
	cur := b
	for p in path {
		nb, ok := find(cur, p)
		if !ok do return nil, false
		cur = nb
	}
	return cur, true
}

@(private = "file")
parse_moov :: proc(d: ^Demuxer, m: ^Mp4, moov: []u8) {
	cs := make([dynamic]Child, context.temp_allocator)
	children(moov, &cs)
	for c in cs {
		switch c.type {
		case "mvex":
			ms := make([dynamic]Child, context.temp_allocator)
			children(c.body, &ms)
			for x in ms {
				if x.type == "trex" && len(x.body) >= 24 {
					append(&m.trex, Trex{be32(x.body[4:]), be32(x.body[12:]), be32(x.body[16:]), be32(x.body[20:])})
				}
			}
		}
	}
	for c in cs {
		if c.type == "trak" do parse_trak(d, m, c.body)
	}
}

@(private = "file")
parse_trak :: proc(d: ^Demuxer, m: ^Mp4, trak: []u8) {
	t: Track
	tkhd, ok := find(trak, "tkhd")
	if !ok || len(tkhd) < 24 do return
	t.id = int(tkhd[0] == 1 ? be32(tkhd[20:]) : be32(tkhd[12:]))
	mdia, ok2 := find(trak, "mdia")
	if !ok2 do return
	mdhd, _ := find(mdia, "mdhd")
	if len(mdhd) >= 24 {
		if mdhd[0] == 1 {
			t.timescale = i64(be32(mdhd[20:]))
			t.duration = i64(be64(mdhd[24:]))
		} else {
			t.timescale = i64(be32(mdhd[12:]))
			t.duration = i64(be32(mdhd[16:]))
		}
	}
	if t.timescale <= 0 do t.timescale = 1000
	hdlr, _ := find(mdia, "hdlr")
	if len(hdlr) >= 12 {
		switch string(hdlr[8:12]) {
		case "vide": t.kind = .Video
		case "soun": t.kind = .Audio
		}
	}
	// Edit list: first non-empty edit's media_time shifts presentation (B-frame
	// delay, AAC priming).
	shift: i64 = 0
	if elst, eok := find_path(trak, "edts", "elst"); eok && len(elst) >= 8 {
		n := int(be32(elst[4:]))
		v1 := elst[0] == 1
		es := v1 ? 20 : 12
		for i in 0 ..< n {
			e := elst[8 + i * es:]
			if len(e) < es do break
			mt := v1 ? i64(be64(e[8:])) : i64(i32(be32(e[4:])))
			if mt >= 0 {
				shift = mt
				break
			}
		}
	}
	m.elst_shift[u32(t.id)] = shift

	stbl, sok := find_path(mdia, "minf", "stbl")
	if !sok {
		append(&d.tracks, t)
		return
	}
	if stsd, ok3 := find(stbl, "stsd"); ok3 && len(stsd) >= 16 {
		parse_stsd(&t, stsd[8:])
	}
	build_sample_table(&t, stbl, shift)
	if t.duration > 0 do t.duration = max(t.duration - shift, 0)
	append(&d.tracks, t)
}

@(private = "file")
parse_stsd :: proc(t: ^Track, entry_box: []u8) {
	// entry_box = first sample entry box (size, type, body)
	if len(entry_box) < 16 do return
	size := int(be32(entry_box))
	if size > len(entry_box) || size < 16 do return
	fmt4 := string(entry_box[4:8])
	body := entry_box[8:size]
	switch fmt4 {
	case "avc1", "avc3", "hvc1", "hev1", "vp09", "vp08", "av01":
		if len(body) < 78 do return
		t.width = int(be16(body[24:]))
		t.height = int(be16(body[26:]))
		ext := body[78:]
		switch fmt4 {
		case "avc1", "avc3":
			t.codec = .H264
			if b, ok := find(ext, "avcC"); ok do t.extradata = clone_bytes(b)
		case "hvc1", "hev1":
			t.codec = .HEVC
			if b, ok := find(ext, "hvcC"); ok do t.extradata = clone_bytes(b)
		case "vp09":
			t.codec = .VP9
			if b, ok := find(ext, "vpcC"); ok do t.extradata = clone_bytes(b)
		case "vp08":
			t.codec = .VP8
		case "av01":
			t.codec = .AV1
			if b, ok := find(ext, "av1C"); ok do t.extradata = clone_bytes(b)
		}
	case "mp4a", "Opus", "fLaC", ".mp3", "lpcm", "sowt", "twos", "ipcm", "fpcm":
		if len(body) < 28 do return
		version := be16(body[8:])
		t.channels = int(be16(body[16:]))
		t.bits = int(be16(body[18:]))
		t.sample_rate = int(be32(body[24:]) >> 16)
		ext_off := 28
		if version == 1 do ext_off += 16
		if version == 2 {
			ext_off += 36
			if len(body) >= 72 {
				// v2: sample rate f64 at 32, channels at 40
				t.channels = int(be32(body[40:]))
			}
		}
		if ext_off > len(body) do return
		ext := body[ext_off:]
		switch fmt4 {
		case "mp4a":
			t.codec = .AAC
			if esds, ok := find(ext, "esds"); ok && len(esds) > 4 {
				t.extradata = clone_bytes(esds[4:])
				oti, asc := parse_es_descriptor(esds[4:])
				if oti == 0x6B || oti == 0x69 do t.codec = .MP3
				if len(asc) > 0 do t.aac_asc = clone_bytes(asc)
			} else if wave, wok := find(ext, "wave"); wok {
				if esds2, ok2 := find(wave, "esds"); ok2 && len(esds2) > 4 {
					t.extradata = clone_bytes(esds2[4:])
					_, asc := parse_es_descriptor(esds2[4:])
					if len(asc) > 0 do t.aac_asc = clone_bytes(asc)
				}
			}
		case ".mp3":
			t.codec = .MP3
		case "Opus":
			t.codec = .Opus
			if dops, ok := find(ext, "dOps"); ok && len(dops) >= 11 {
				t.extradata = opus_head_from_dops(dops)
				t.pre_skip = int(be16(dops[2:]))
				t.channels = int(dops[1])
			}
			t.sample_rate = 48000
		case "fLaC":
			t.codec = .FLAC
			if dfla, ok := find(ext, "dfLa"); ok && len(dfla) > 4 {
				// FullBox; then metadata blocks (first is STREAMINFO)
				t.extradata = clone_bytes(dfla[4:])
			}
		case "lpcm", "sowt", "twos", "ipcm", "fpcm":
			t.codec = .PCM
			t.pcm_big = fmt4 == "twos"
			t.pcm_float = fmt4 == "fpcm"
		}
	}
}

// Returns objectTypeIndication and DecoderSpecificInfo from an ES_Descriptor.
@(private)
parse_es_descriptor :: proc(b: []u8) -> (oti: u8, dsi: []u8) {
	i := 0
	read_desc :: proc(b: []u8, i: ^int) -> (tag: u8, size: int, ok: bool) {
		if i^ >= len(b) do return
		tag = b[i^]
		i^ += 1
		for _ in 0 ..< 4 {
			if i^ >= len(b) do return
			c := b[i^]
			i^ += 1
			size = size << 7 | int(c & 0x7f)
			if c & 0x80 == 0 do break
		}
		ok = true
		return
	}
	tag, size, ok := read_desc(b, &i)
	if !ok || tag != 3 do return
	end := min(i + size, len(b))
	if i + 3 > end do return
	flags := b[i + 2]
	i += 3
	if flags & 0x80 != 0 do i += 2
	if flags & 0x40 != 0 {
		if i < end do i += 1 + int(b[i])
	}
	if flags & 0x20 != 0 do i += 2
	for i < end {
		t2, s2, ok2 := read_desc(b, &i)
		if !ok2 do return
		if t2 == 4 {
			if i < len(b) do oti = b[i]
			j := i + 13
			e2 := min(i + s2, len(b))
			for j < e2 {
				t3, s3, ok3 := read_desc(b, &j)
				if !ok3 do return
				if t3 == 5 {
					dsi = b[j:min(j + s3, len(b))]
					return
				}
				j += s3
			}
			return
		}
		i += s2
	}
	return
}

@(private = "file")
opus_head_from_dops :: proc(dops: []u8) -> []u8 {
	// dOps (big endian) -> OpusHead (little endian)
	h := make([dynamic]u8)
	append(&h, ..transmute([]u8)string("OpusHead"))
	append(&h, 1, dops[1])
	ps := be16(dops[2:])
	append(&h, u8(ps), u8(ps >> 8))
	sr := be32(dops[4:])
	append(&h, u8(sr), u8(sr >> 8), u8(sr >> 16), u8(sr >> 24))
	g := be16(dops[8:])
	append(&h, u8(g), u8(g >> 8))
	append(&h, dops[10])
	if dops[10] != 0 && len(dops) > 11 do append(&h, ..dops[11:])
	return h[:]
}

@(private = "file")
build_sample_table :: proc(t: ^Track, stbl: []u8, shift: i64) {
	stts, _ := find(stbl, "stts")
	ctts, has_ctts := find(stbl, "ctts")
	stsc, _ := find(stbl, "stsc")
	stsz, _ := find(stbl, "stsz")
	stss, has_stss := find(stbl, "stss")
	stco, has_stco := find(stbl, "stco")
	co64, _ := find(stbl, "co64")
	if len(stsz) < 12 || len(stts) < 8 || len(stsc) < 8 do return

	count := min(int(be32(stsz[8:])), 10_000_000)
	fixed_size := be32(stsz[4:])
	if fixed_size == 0 do count = min(count, (len(stsz) - 12) / 4)
	if reserve(&t.packets, count) != nil do return

	// sizes + dts
	stts_n := min(int(be32(stts[4:])), (len(stts) - 8) / 8)
	e, left: int
	dts: i64 = 0
	ctts_n := has_ctts && len(ctts) >= 8 ? min(int(be32(ctts[4:])), (len(ctts) - 8) / 8) : 0
	ce, cleft: int
	if stts_n > 0 do left = int(be32(stts[8:]))
	if ctts_n > 0 do cleft = int(be32(ctts[8:]))
	for i in 0 ..< count {
		p: Packet_Ref
		p.size = i32(fixed_size != 0 ? fixed_size : (12 + i * 4 + 4 <= len(stsz) ? be32(stsz[12 + i * 4:]) : 0))
		for left == 0 && e + 1 < stts_n {
			e += 1
			left = int(be32(stts[8 + e * 8:]))
		}
		delta := i64(e < stts_n ? be32(stts[12 + e * 8:]) : 0)
		left -= 1
		cto: i64 = 0
		if ctts_n > 0 {
			for cleft == 0 && ce + 1 < ctts_n {
				ce += 1
				cleft = int(be32(ctts[8 + ce * 8:]))
			}
			cto = i64(i32(be32(ctts[12 + ce * 8:])))
			cleft -= 1
		}
		p.dts = dts - shift
		p.pts = dts + cto - shift
		p.dur = i32(delta)
		p.key = !has_stss
		dts += delta
		append(&t.packets, p)
	}
	if has_stss && len(stss) >= 8 {
		n := int(be32(stss[4:]))
		for i in 0 ..< n {
			if 8 + i * 4 + 4 > len(stss) do break
			k := int(be32(stss[8 + i * 4:])) - 1
			if k >= 0 && k < count do t.packets[k].key = true
		}
	}
	// chunk offsets
	nchunks := has_stco ? int(be32(stco[4:])) : (len(co64) >= 8 ? int(be32(co64[4:])) : 0)
	chunk_off :: proc(stco, co64: []u8, has_stco: bool, c: int) -> i64 {
		if has_stco do return i64(be32(stco[8 + c * 4:]))
		return i64(be64(co64[8 + c * 8:]))
	}
	stsc_n := int(be32(stsc[4:]))
	s := 0
	for ent in 0 ..< stsc_n {
		first := int(be32(stsc[8 + ent * 12:])) - 1
		per := int(be32(stsc[12 + ent * 12:]))
		last := ent + 1 < stsc_n ? int(be32(stsc[8 + (ent + 1) * 12:])) - 1 : nchunks
		for c in first ..< min(last, nchunks) {
			off := chunk_off(stco, co64, has_stco, c)
			for _ in 0 ..< per {
				if s >= count do return
				t.packets[s].offset = off
				off += i64(t.packets[s].size)
				s += 1
			}
		}
	}
}

@(private = "file")
parse_moof :: proc(d: ^Demuxer, m: ^Mp4, moof: []u8, moof_start: i64) {
	cs := make([dynamic]Child, context.temp_allocator)
	children(moof, &cs)
	for c in cs {
		if c.type != "traf" do continue
		tcs := make([dynamic]Child, context.temp_allocator)
		children(c.body, &tcs)
		tfhd: []u8
		for x in tcs do if x.type == "tfhd" do tfhd = x.body
		if len(tfhd) < 8 do continue
		fl := be24(tfhd[1:])
		tid := be32(tfhd[4:])
		i := 8
		base := moof_start
		if fl & 0x1 != 0 {base = i64(be64(tfhd[i:])); i += 8}
		if fl & 0x2 != 0 do i += 4
		trex: Trex
		for tr in m.trex do if tr.track_id == tid do trex = tr
		def_dur, def_size, def_flags := trex.def_dur, trex.def_size, trex.def_flags
		if fl & 0x8 != 0 {def_dur = be32(tfhd[i:]); i += 4}
		if fl & 0x10 != 0 {def_size = be32(tfhd[i:]); i += 4}
		if fl & 0x20 != 0 {def_flags = be32(tfhd[i:]); i += 4}
		track: ^Track
		for &t in d.tracks do if u32(t.id) == tid do track = &t
		if track == nil do continue
		shift := m.elst_shift[tid]
		dts, has_dts := m.frag_dts[tid]
		if !has_dts do dts = 0
		for x in tcs {
			if x.type == "tfdt" && len(x.body) >= 8 {
				dts = x.body[0] == 1 ? i64(be64(x.body[4:])) : i64(be32(x.body[4:]))
			}
		}
		data_end := base // running data pointer for successive truns without offset
		for x in tcs {
			if x.type != "trun" || len(x.body) < 8 do continue
			b := x.body
			tf := be24(b[1:])
			n := int(be32(b[4:]))
			j := 8
			ptr := data_end
			if tf & 0x1 != 0 {ptr = base + i64(i32(be32(b[j:]))); j += 4}
			first_flags := def_flags
			has_first := tf & 0x4 != 0
			if has_first {first_flags = be32(b[j:]); j += 4}
			for k in 0 ..< n {
				dur, size, sfl: u32 = def_dur, def_size, (k == 0 && has_first) ? first_flags : def_flags
				cto: i64 = 0
				if tf & 0x100 != 0 {dur = be32(b[j:]); j += 4}
				if tf & 0x200 != 0 {size = be32(b[j:]); j += 4}
				if tf & 0x400 != 0 {
					f := be32(b[j:])
					j += 4
					if !(k == 0 && has_first) do sfl = f
				}
				if tf & 0x800 != 0 {
					cto = b[0] == 0 ? i64(be32(b[j:])) : i64(i32(be32(b[j:])))
					j += 4
				}
				if j > len(b) do break
				append(&track.packets, Packet_Ref{
					offset = ptr, size = i32(size), dts = dts - shift, pts = dts + cto - shift,
					dur = i32(dur), key = sfl & 0x10000 == 0,
				})
				ptr += i64(size)
				dts += i64(dur)
			}
			data_end = ptr
		}
		m.frag_dts[tid] = dts
	}
}
