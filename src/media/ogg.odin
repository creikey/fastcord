package media

// Ogg pages -> logical-stream packets. Opus (voice messages), Vorbis and FLAC
// headers are recognized; packets spanning pages are recorded as pieces.

@(private = "file")
Ogg_Stream :: struct {
	serial:       u32,
	track:        int, // index into d.tracks, -1 = ignored stream
	headers_left: int, // header packets still to skip
	cur_size:     i32, // partial packet being assembled
	cur_pieces:   [dynamic]Piece,
	next_pts:     i64, // running sample position (before pre-skip)
	pending:      [dynamic]int, // packet indices completed in this page, pts fixup
}

@(private = "file")
Ogg :: struct {
	streams: [dynamic]Ogg_Stream,
}

@(private)
ogg_init :: proc(d: ^Demuxer) {
	d.format = .Ogg
	o := new(Ogg)
	d.state = o
	d.scan_proc = ogg_scan
	d.free_proc = proc(d: ^Demuxer) {
		o := (^Ogg)(d.state)
		for &s in o.streams {
			delete(s.pending)
			delete(s.cur_pieces)
		}
		delete(o.streams)
		free(o)
	}
}

// Samples (48 kHz) in an Opus packet, from its TOC byte(s). RFC 6716 3.1.
opus_packet_samples :: proc(p: []u8) -> int {
	if len(p) < 1 do return 0
	toc := p[0]
	cfg := int(toc >> 3)
	SILK := [4]int{480, 960, 1920, 2880}
	CELT := [4]int{120, 240, 480, 960}
	frame: int // samples at 48 kHz
	switch {
	case cfg < 12:
		frame = SILK[cfg & 3]
	case cfg < 16:
		frame = (cfg & 1) == 0 ? 480 : 960
	case:
		frame = CELT[cfg & 3]
	}
	count := 1
	switch toc & 3 {
	case 1, 2: count = 2
	case 3:
		if len(p) < 2 do return 0
		count = int(p[1] & 0x3f)
	}
	return frame * count
}

@(private = "file")
ogg_scan :: proc(d: ^Demuxer) -> Scan_Status {
	o := (^Ogg)(d.state)
	avail, complete := source_extent(d.src)
	at := d.scan_pos
	if at >= avail {
		if complete do return .Done
		reader_reset(&d.reader)
		return .Need_Data
	}
	h, s := peek(&d.reader, at, 27)
	if s != .Ok {
		if complete do return .Done
		reader_reset(&d.reader)
		return .Need_Data
	}
	if string(h[:4]) != "OggS" {
		// resync
		d.scan_pos += 1
		return .Progress
	}
	htype := h[5]
	granule := i64(le64(h[6:]))
	serial := le32(h[14:])
	nseg := int(h[26])
	lacing, ls := peek(&d.reader, at + 27, nseg)
	if ls != .Ok {
		if complete do return .Done
		reader_reset(&d.reader)
		return .Need_Data
	}
	lac := make([]u8, nseg, context.temp_allocator)
	copy(lac, lacing)
	body_at := at + 27 + i64(nseg)
	body_len: i64
	for l in lac do body_len += i64(l)
	if body_at + body_len > avail {
		if complete do return .Done
		reader_reset(&d.reader)
		return .Need_Data
	}

	st: ^Ogg_Stream
	for &x in o.streams do if x.serial == serial do st = &x
	if st == nil {
		append(&o.streams, Ogg_Stream{serial = serial, track = -1})
		st = &o.streams[len(o.streams) - 1]
	}
	_ = htype
	clear(&st.pending)

	pos := body_at
	for i := 0; i < nseg; {
		// gather segments of one packet within this page
		seg_start := pos
		size: i64
		done := false
		for i < nseg {
			l := lac[i]
			size += i64(l)
			i += 1
			if l < 255 {
				done = true
				break
			}
		}
		pos += size
		if size > 0 do append(&st.cur_pieces, Piece{seg_start, i32(size)})
		st.cur_size += i32(size)
		if !done do break // continues on next page
		finish_packet(d, st)
	}
	// granule = end position of the last packet completed on this page
	if granule >= 0 && len(st.pending) > 0 && st.track >= 0 {
		t := &d.tracks[st.track]
		end := granule
		for k := len(st.pending) - 1; k >= 0; k -= 1 {
			p := &t.packets[st.pending[k]]
			p.pts = end - i64(p.dur) - i64(t.pre_skip)
			p.dts = p.pts
			end -= i64(p.dur)
		}
		st.next_pts = granule
		t.duration = granule - i64(t.pre_skip)
	}
	d.scan_pos = body_at + body_len
	return .Progress
}

@(private = "file")
finish_packet :: proc(d: ^Demuxer, st: ^Ogg_Stream) {
	defer {
		st.cur_size = 0
		clear(&st.cur_pieces)
	}
	if len(st.cur_pieces) == 0 do return
	ref := Packet_Ref{offset = st.cur_pieces[0].offset, size = st.cur_size}
	if len(st.cur_pieces) > 1 {
		ref.pieces = i32(len(st.cur_pieces))
		ref.piece_at = i32(len(d.pieces))
		append(&d.pieces, ..st.cur_pieces[:])
	}
	if st.track < 0 && st.headers_left == 0 {
		// first packet of the stream: identify codec
		head := make([dynamic]u8, context.temp_allocator)
		if demux_read(d, ref, &head) != .Ok do return
		t: Track
		t.id = int(st.serial)
		t.kind = .Audio
		switch {
		case len(head) >= 19 && string(head[:8]) == "OpusHead":
			t.codec = .Opus
			t.channels = int(head[9])
			t.pre_skip = int(le16(head[10:]))
			t.sample_rate = 48000
			t.timescale = 48000
			t.extradata = clone_bytes(head[:])
			st.headers_left = 1 // OpusTags
		case len(head) >= 30 && head[0] == 1 && string(head[1:7]) == "vorbis":
			t.codec = .Vorbis
			t.channels = int(head[11])
			t.sample_rate = int(le32(head[12:]))
			t.timescale = i64(t.sample_rate)
			t.extradata = clone_bytes(head[:])
			st.headers_left = 2
		case len(head) >= 51 && head[0] == 0x7F && string(head[1:5]) == "FLAC":
			t.codec = .FLAC
			t.extradata = clone_bytes(head[13:]) // STREAMINFO metadata block
			si := head[17:]
			t.sample_rate = int(be24(si[10:]) >> 4)
			t.channels = int((si[12] >> 1) & 7) + 1
			t.timescale = i64(t.sample_rate)
			st.headers_left = int(be16(head[7:])) // further header packets
		case:
			st.headers_left = -1 // unknown stream: ignore forever
			return
		}
		st.track = len(d.tracks)
		append(&d.tracks, t)
		d.ready = st.headers_left == 0
		return
	}
	if st.headers_left > 0 {
		st.headers_left -= 1
		if st.headers_left == 0 do d.ready = true
		return
	}
	if st.track < 0 do return
	t := &d.tracks[st.track]
	if t.codec == .Opus {
		toc: [2]u8
		n := min(int(ref.size), 2)
		first := ref.pieces > 0 ? d.pieces[ref.piece_at].offset : ref.offset
		read_full(d.src, first, toc[:n])
		ref.dur = i32(opus_packet_samples(toc[:n]))
	}
	ref.key = true
	ref.pts = st.next_pts - i64(t.pre_skip)
	ref.dts = ref.pts
	st.next_pts += i64(ref.dur)
	append(&st.pending, len(t.packets))
	append(&t.packets, ref)
}
