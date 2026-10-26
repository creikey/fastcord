package media

// Matroska / WebM. Walks the EBML tree incrementally: Info and Tracks are read
// whole; Clusters are descended into and every (Simple)Block header is indexed
// (lacing resolved), payloads are not read during scanning.

@(private = "file") ID_EBML :: 0x1A45DFA3
@(private = "file") ID_SEGMENT :: 0x18538067
@(private = "file") ID_INFO :: 0x1549A966
@(private = "file") ID_TIMECODE_SCALE :: 0x2AD7B1
@(private = "file") ID_DURATION :: 0x4489
@(private = "file") ID_TRACKS :: 0x1654AE6B
@(private = "file") ID_TRACK_ENTRY :: 0xAE
@(private = "file") ID_TRACK_NUMBER :: 0xD7
@(private = "file") ID_TRACK_TYPE :: 0x83
@(private = "file") ID_CODEC_ID :: 0x86
@(private = "file") ID_CODEC_PRIVATE :: 0x63A2
@(private = "file") ID_CODEC_DELAY :: 0x56AA
@(private = "file") ID_DEFAULT_DURATION :: 0x23E383
@(private = "file") ID_VIDEO :: 0xE0
@(private = "file") ID_PIXEL_WIDTH :: 0xB0
@(private = "file") ID_PIXEL_HEIGHT :: 0xBA
@(private = "file") ID_AUDIO :: 0xE1
@(private = "file") ID_SAMPLING_FREQ :: 0xB5
@(private = "file") ID_CHANNELS :: 0x9F
@(private = "file") ID_BIT_DEPTH :: 0x6264
@(private = "file") ID_CLUSTER :: 0x1F43B675
@(private = "file") ID_CLUSTER_TIMECODE :: 0xE7
@(private = "file") ID_SIMPLE_BLOCK :: 0xA3
@(private = "file") ID_BLOCK_GROUP :: 0xA0
@(private = "file") ID_BLOCK :: 0xA1
@(private = "file") ID_BLOCK_DURATION :: 0x9B
@(private = "file") ID_REFERENCE_BLOCK :: 0xFB

@(private = "file")
UNKNOWN_SIZE :: max(i64)

@(private = "file")
Mkv :: struct {
	seg_start:    i64,
	seg_end:      i64,
	tc_scale:     i64, // ns per tick
	duration:     f64, // in ticks
	have_tracks:  bool,
	// cluster walk state
	in_cluster:   bool,
	cluster_end:  i64,
	cluster_tc:   i64,
	track_map:    map[int]int, // track number -> index in d.tracks
	default_dur:  map[int]i64, // ns
	last_pts:     map[int]i64,
}

@(private)
mkv_init :: proc(d: ^Demuxer) {
	d.format = .Matroska
	m := new(Mkv)
	m.tc_scale = 1_000_000
	m.seg_start = -1
	d.state = m
	d.scan_proc = mkv_scan
	d.free_proc = proc(d: ^Demuxer) {
		m := (^Mkv)(d.state)
		delete(m.track_map)
		delete(m.default_dur)
		delete(m.last_pts)
		free(m)
	}
}

// EBML variable-length integer. keep_marker for IDs.
@(private = "file")
vint :: proc(b: []u8, keep_marker: bool) -> (v: i64, n: int, ok: bool) {
	if len(b) == 0 || b[0] == 0 do return
	first := b[0]
	n = 1
	mask: u8 = 0x80
	for first & mask == 0 {
		n += 1
		mask >>= 1
	}
	if n > 8 || len(b) < n do return 0, 0, false
	v = i64(keep_marker ? first : first & (mask - 1))
	all_ones := (first & (mask - 1)) == mask - 1
	for i in 1 ..< n {
		v = v << 8 | i64(b[i])
		if b[i] != 0xFF do all_ones = false
	}
	if !keep_marker && all_ones do v = UNKNOWN_SIZE
	ok = true
	return
}

@(private = "file")
Elem :: struct {
	id:   i64,
	size: i64,
	hdr:  int,
}

@(private = "file")
read_elem :: proc(d: ^Demuxer, at: i64) -> (Elem, Read_Status) {
	b, s := peek(&d.reader, at, 12)
	if s != .Ok {
		// near EOF: try smaller
		avail, _ := source_extent(d.src)
		n := int(min(avail - at, 12))
		if n < 2 do return {}, s
		b, s = peek(&d.reader, at, n)
		if s != .Ok do return {}, s
	}
	id, n1, ok := vint(b, true)
	if !ok do return {}, .Error
	size, n2, ok2 := vint(b[n1:], false)
	if !ok2 do return {}, .Pending
	return {id, size, n1 + n2}, .Ok
}

@(private = "file")
uint_of :: proc(b: []u8) -> i64 {
	v: i64
	for x in b do v = v << 8 | i64(x)
	return v
}

@(private = "file")
float_of :: proc(b: []u8) -> f64 {
	if len(b) == 4 do return f64(transmute(f32)be32(b))
	if len(b) == 8 do return transmute(f64)be64(b)
	return 0
}

// Iterate elements in a fully-loaded buffer.
@(private = "file")
each :: proc(b: []u8, i: ^int) -> (id: i64, body: []u8, ok: bool) {
	if i^ >= len(b) do return
	id_, n1, ok1 := vint(b[i^:], true)
	if !ok1 do return
	size, n2, ok2 := vint(b[i^ + n1:], false)
	if !ok2 do return
	start := i^ + n1 + n2
	end := size == UNKNOWN_SIZE ? len(b) : min(start + int(size), len(b))
	i^ = end
	return id_, b[start:end], true
}

@(private = "file")
mkv_scan :: proc(d: ^Demuxer) -> Scan_Status {
	m := (^Mkv)(d.state)
	avail, complete := source_extent(d.src)
	if m.seg_start < 0 {
		// EBML header then Segment
		e, s := read_elem(d, 0)
		if s != .Ok do return s == .Error ? .Error : .Need_Data
		if e.id != ID_EBML do return .Error
		at := i64(e.hdr) + e.size
		seg, s2 := read_elem(d, at)
		if s2 != .Ok do return s2 == .Error ? .Error : .Need_Data
		if seg.id != ID_SEGMENT do return .Error
		m.seg_start = at + i64(seg.hdr)
		m.seg_end = seg.size == UNKNOWN_SIZE ? max(i64) : m.seg_start + seg.size
		d.scan_pos = m.seg_start
		return .Progress
	}
	if d.scan_pos >= min(m.seg_end, avail) {
		if complete || d.scan_pos >= m.seg_end {
			m.in_cluster = false
			return .Done
		}
		reader_reset(&d.reader)
		return .Need_Data
	}
	e, s := read_elem(d, d.scan_pos)
	if s != .Ok {
		if s == .Error do return .Error
		if complete do return .Done
		reader_reset(&d.reader)
		return .Need_Data
	}
	body_at := d.scan_pos + i64(e.hdr)

	if m.in_cluster {
		if d.scan_pos >= m.cluster_end || is_top_level(e.id) {
			m.in_cluster = false
			return .Progress
		}
		switch e.id {
		case ID_CLUSTER_TIMECODE:
			b, rs := peek(&d.reader, body_at, int(e.size))
			if rs != .Ok do return .Need_Data
			m.cluster_tc = uint_of(b)
		case ID_SIMPLE_BLOCK:
			if body_at + e.size > avail do return complete ? .Done : .Need_Data
			index_block(d, m, body_at, e.size, true, -1, false)
		case ID_BLOCK_GROUP:
			if body_at + e.size > avail do return complete ? .Done : .Need_Data
			// find Block, BlockDuration, ReferenceBlock
			pos := body_at
			end := body_at + e.size
			blk_at, blk_size: i64 = -1, 0
			dur: i64 = -1
			has_ref := false
			for pos < end {
				c, cs := read_elem(d, pos)
				if cs != .Ok do break
				cb := pos + i64(c.hdr)
				switch c.id {
				case ID_BLOCK:
					blk_at, blk_size = cb, c.size
				case ID_BLOCK_DURATION:
					if b, rs := peek(&d.reader, cb, int(c.size)); rs == .Ok do dur = uint_of(b)
				case ID_REFERENCE_BLOCK:
					has_ref = true
				}
				pos = cb + c.size
			}
			if blk_at >= 0 do index_block(d, m, blk_at, blk_size, false, dur, !has_ref)
		}
		d.scan_pos = body_at + (e.size == UNKNOWN_SIZE ? 0 : e.size)
		return .Progress
	}

	switch e.id {
	case ID_INFO, ID_TRACKS:
		if e.size == UNKNOWN_SIZE do return .Error
		if body_at + e.size > avail do return complete ? .Error : .Need_Data
		body := make([]u8, e.size)
		defer delete(body)
		if read_full(d.src, body_at, body) != .Ok do return .Need_Data
		if e.id == ID_INFO do parse_info(m, body)
		else {
			parse_tracks(d, m, body)
			m.have_tracks = true
		}
		d.scan_pos = body_at + e.size
	case ID_CLUSTER:
		if !m.have_tracks do return .Error
		d.ready = true
		m.in_cluster = true
		m.cluster_end = e.size == UNKNOWN_SIZE ? max(i64) : body_at + e.size
		m.cluster_tc = 0
		d.scan_pos = body_at
	case:
		if e.size == UNKNOWN_SIZE do return .Error
		d.scan_pos = body_at + e.size
	}
	return .Progress
}

@(private = "file")
is_top_level :: proc(id: i64) -> bool {
	switch id {
	case ID_CLUSTER, ID_INFO, ID_TRACKS, 0x1C53BB6B, 0x1254C367, 0x1043A770, 0x114D9B74, 0x1941A469:
		return true
	}
	return false
}

@(private = "file")
parse_info :: proc(m: ^Mkv, b: []u8) {
	i := 0
	for {
		id, body, ok := each(b, &i)
		if !ok do break
		switch id {
		case ID_TIMECODE_SCALE: m.tc_scale = max(uint_of(body), 1)
		case ID_DURATION: m.duration = float_of(body)
		}
	}
}

@(private = "file")
parse_tracks :: proc(d: ^Demuxer, m: ^Mkv, b: []u8) {
	i := 0
	for {
		id, body, ok := each(b, &i)
		if !ok do break
		if id != ID_TRACK_ENTRY do continue
		t: Track
		t.timescale = 1_000_000_000 / m.tc_scale
		t.duration = i64(m.duration)
		codec_id: string
		codec_delay_ns: i64
		j := 0
		for {
			cid, cb, cok := each(body, &j)
			if !cok do break
			switch cid {
			case ID_TRACK_NUMBER: t.id = int(uint_of(cb))
			case ID_TRACK_TYPE:
				switch uint_of(cb) {
				case 1: t.kind = .Video
				case 2: t.kind = .Audio
				}
			case ID_CODEC_ID: codec_id = string(cb)
			case ID_CODEC_PRIVATE: t.extradata = clone_bytes(cb)
			case ID_CODEC_DELAY: codec_delay_ns = uint_of(cb)
			case ID_DEFAULT_DURATION: m.default_dur[t.id] = uint_of(cb)
			case ID_VIDEO:
				k := 0
				for {
					vid, vb, vok := each(cb, &k)
					if !vok do break
					if vid == ID_PIXEL_WIDTH do t.width = int(uint_of(vb))
					if vid == ID_PIXEL_HEIGHT do t.height = int(uint_of(vb))
				}
			case ID_AUDIO:
				k := 0
				for {
					aid, ab, aok := each(cb, &k)
					if !aok do break
					switch aid {
					case ID_SAMPLING_FREQ: t.sample_rate = int(float_of(ab))
					case ID_CHANNELS: t.channels = int(uint_of(ab))
					case ID_BIT_DEPTH: t.bits = int(uint_of(ab))
					}
				}
			}
		}
		// codec_id is a view into body; resolve before body goes away
		switch {
		case codec_id == "V_MPEG4/ISO/AVC": t.codec = .H264
		case codec_id == "V_MPEGH/ISO/HEVC": t.codec = .HEVC
		case codec_id == "V_VP8": t.codec = .VP8
		case codec_id == "V_VP9": t.codec = .VP9
		case codec_id == "V_AV1": t.codec = .AV1
		case codec_id == "A_OPUS":
			t.codec = .Opus
			if len(t.extradata) >= 12 do t.pre_skip = int(le16(t.extradata[10:]))
			else do t.pre_skip = int(codec_delay_ns * 48000 / 1_000_000_000)
		case codec_id == "A_VORBIS": t.codec = .Vorbis
		case codec_id == "A_FLAC": t.codec = .FLAC
		case codec_id == "A_MPEG/L3": t.codec = .MP3
		case len(codec_id) >= 5 && codec_id[:5] == "A_AAC":
			t.codec = .AAC
			t.aac_asc = clone_bytes(t.extradata)
		case codec_id == "A_PCM/INT/LIT": t.codec = .PCM
		case codec_id == "A_PCM/INT/BIG": t.codec = .PCM; t.pcm_big = true
		case codec_id == "A_PCM/FLOAT/IEEE": t.codec = .PCM; t.pcm_float = true
		}
		if t.codec == .FLAC && len(t.extradata) > 4 && string(t.extradata[:4]) == "fLaC" {
			// keep metadata blocks only, like MP4 dfLa
			nb := clone_bytes(t.extradata[4:])
			delete(t.extradata)
			t.extradata = nb
		}
		m.track_map[t.id] = len(d.tracks)
		append(&d.tracks, t)
	}
}

@(private = "file")
index_block :: proc(d: ^Demuxer, m: ^Mkv, at: i64, size: i64, simple: bool, block_dur: i64, group_key: bool) {
	hb, s := peek(&d.reader, at, int(min(size, 64)))
	if s != .Ok do return
	tn, n, ok := vint(hb, false)
	if !ok || len(hb) < n + 3 do return
	ti, has := m.track_map[int(tn)]
	if !has do return
	t := &d.tracks[ti]
	rel := i64(i16(be16(hb[n:])))
	flags := hb[n + 2]
	key := simple ? flags & 0x80 != 0 : group_key
	if t.kind == .Audio do key = true
	pts := m.cluster_tc + rel
	hdr := i64(n + 3)
	lacing := (flags >> 1) & 3
	payload_at := at + hdr
	payload_size := size - hdr
	dur := i32(block_dur)
	if dur <= 0 {
		if dd, okd := m.default_dur[t.id]; okd do dur = i32(dd / m.tc_scale)
	}
	if lacing == 0 {
		append(&t.packets, Packet_Ref{offset = payload_at, size = i32(payload_size), pts = pts, dts = pts, dur = dur, key = key})
		return
	}
	// Laced: frame count, then sizes
	lb, ls := peek(&d.reader, payload_at, int(min(payload_size, 4096)))
	if ls != .Ok || len(lb) < 1 do return
	count := int(lb[0]) + 1
	sizes := make([]i64, count, context.temp_allocator)
	p := 1
	switch lacing {
	case 1: // Xiph
		for k in 0 ..< count - 1 {
			v: i64
			for p < len(lb) {
				c := lb[p]
				p += 1
				v += i64(c)
				if c != 255 do break
			}
			sizes[k] = v
		}
	case 3: // EBML
		first, fn, fok := vint(lb[p:], false)
		if !fok do return
		p += fn
		sizes[0] = first
		for k in 1 ..< count - 1 {
			raw, rn, rok := vint(lb[p:], false)
			if !rok do return
			p += rn
			bias := (i64(1) << uint(7 * rn - 1)) - 1
			sizes[k] = sizes[k - 1] + (raw - bias)
		}
	case 2: // fixed
		each_size := (payload_size - 1) / i64(count)
		for k in 0 ..< count do sizes[k] = each_size
	}
	total: i64
	for k in 0 ..< count - 1 do total += sizes[k]
	if lacing != 2 do sizes[count - 1] = payload_size - i64(p) - total
	for k in 0 ..< count do if sizes[k] < 0 || sizes[k] > payload_size do return
	off := payload_at + i64(p)
	frame_dur := dur > 0 ? dur / i32(count) : 0
	for k in 0 ..< count {
		append(&t.packets, Packet_Ref{offset = off, size = i32(sizes[k]), pts = pts + i64(frame_dur) * i64(k), dts = pts, dur = frame_dur, key = key})
		off += sizes[k]
	}
}
