#scope_file

// Ogg pages -> logical-stream packets. Opus (voice messages), Vorbis and FLAC
// headers are recognized; packets spanning pages are recorded as pieces.

Ogg_Stream :: struct {
	serial: u32;
	track: int; // index into d.tracks, -1 = ignored stream
	headers_left: int; // header packets still to skip
	cur_size: s32; // partial packet being assembled
	cur_pieces: [..]Piece;
	next_pts: s64; // running sample position (before pre-skip)
	pending: [..]int; // packet indices completed in this page, pts fixup
}

Ogg :: struct {
	streams: [..]Ogg_Stream;
}
#scope_module

ogg_init :: (d: *Demuxer) {
	d.format = .Ogg;
	o := new(Ogg);
	d.state = o;
	d.scan_proc = ogg_scan;
	d.free_proc = (d: *Demuxer) {
		o := cast(*Ogg)(d.state);
		for * s: o.streams {
			delete(s.pending);
			delete(s.cur_pieces);
		}
		delete(o.streams);
		free(o);
	};
}
#scope_export

// Samples (48 kHz) in an Opus packet, from its TOC byte(s). RFC 6716 3.1.
opus_packet_samples :: (p: []u8) -> int {
	if len(p) < 1 { return 0; }
	toc := p[0];
	cfg := cast(int)(toc >> 3);
	SILK := int.[480, 960, 1920, 2880];
	CELT := int.[120, 240, 480, 960];
	frame: int; // samples at 48 kHz
	if cfg < 12 {
		frame = SILK[cfg & 3];
	} else if cfg < 16 {
		frame = ifx (cfg & 1) == 0 then 480 else 960;
	} else {
		frame = CELT[cfg & 3];
	}
	count := 1;
	if toc & 3 == {
	case 1; #through; case 2; count = 2;
	case 3;
		if len(p) < 2 { return 0; }
		count = cast(int)(p[1] & 0x3f);
	}
	return frame * count;
}
#scope_file

ogg_scan :: (d: *Demuxer) -> Scan_Status {
	o := cast(*Ogg)(d.state);
	avail, complete := source_extent(d.src);
	at := d.scan_pos;
	if at >= avail {
		if complete { return .Done; }
		reader_reset(*d.reader);
		return .Need_Data;
	}
	h, s := peek(*d.reader, at, 27);
	if s != .Ok {
		if complete { return .Done; }
		reader_reset(*d.reader);
		return .Need_Data;
	}
	if as_string(sub(h, 0, 4)) != "OggS" {
		// resync
		d.scan_pos += 1;
		return .Progress;
	}
	htype := h[5];
	granule := cast(s64)(le64(sub_from(h, 6)));
	serial := le32(sub_from(h, 14));
	nseg := cast(int)(h[26]);
	lacing, ls := peek(*d.reader, at + 27, nseg);
	if ls != .Ok {
		if complete { return .Done; }
		reader_reset(*d.reader);
		return .Need_Data;
	}
	lac := make_slice(u8, nseg, temp);
	copy(lac, lacing);
	body_at := at + 27 + cast(s64)(nseg);
	body_len: s64;
	for l: lac { body_len += cast(s64)(l); }
	if body_at + body_len > avail {
		if complete { return .Done; }
		reader_reset(*d.reader);
		return .Need_Data;
	}

	st: *Ogg_Stream;
	for * x: o.streams { if x.serial == serial { st = x; } }
	if st == null {
		append(*o.streams, Ogg_Stream.{serial = serial, track = -1});
		st = *o.streams[o.streams.count - 1];
	}
	clear(*st.pending);

	pos := body_at;
	{ i := 0;
	while i < nseg {
		// gather segments of one packet within this page
		seg_start := pos;
		size: s64;
		done := false;
		while i < nseg {
			l := lac[i];
			size += cast(s64)(l);
			i += 1;
			if l < 255 {
				done = true;
				break;
			}
		}
		pos += size;
		if size > 0 { append(*st.cur_pieces, Piece.{seg_start, cast(s32)(size)}); }
		st.cur_size += cast(s32)(size);
		if !done { break; } // continues on next page
		finish_packet(d, st);
	} }
	// granule = end position of the last packet completed on this page
	if granule >= 0 && len(st.pending) > 0 && st.track >= 0 {
		t := *d.tracks[st.track];
		end := granule;
		for < k: len(st.pending) - 1..0 {
			p := *t.packets[st.pending[k]];
			p.pts = end - cast(s64)(p.dur) - cast(s64)(t.pre_skip);
			p.dts = p.pts;
			end -= cast(s64)(p.dur);
		}
		st.next_pts = granule;
		t.duration = granule - cast(s64)(t.pre_skip);
	}
	d.scan_pos = body_at + body_len;
	return .Progress;
}

finish_packet :: (d: *Demuxer, st: *Ogg_Stream) {
	defer {
		st.cur_size = 0;
		clear(*st.cur_pieces);
	}
	if len(st.cur_pieces) == 0 { return; }
	ref := Packet_Ref.{offset = st.cur_pieces[0].offset, size = st.cur_size};
	if len(st.cur_pieces) > 1 {
		ref.pieces = cast(s32)(len(st.cur_pieces));
		ref.piece_at = cast(s32)(len(d.pieces));
		append(*d.pieces, ..view(st.cur_pieces));
	}
	if st.track < 0 && st.headers_left == 0 {
		// first packet of the stream: identify codec
		head := make_dynamic(u8, 0, 0, temp);
		if demux_read(d, ref, *head) != .Ok { return; }
		t: Track;
		t.id = cast(int)(st.serial);
		t.kind = .Audio;
		if len(head) >= 19 && as_string(sub(head, 0, 8)) == "OpusHead" {
			t.codec = .Opus;
			t.channels = cast(int)(head[9]);
			t.pre_skip = cast(int)(le16(sub_from(head, 10)));
			t.sample_rate = 48000;
			t.timescale = 48000;
			t.extradata = clone_bytes(view(head));
			st.headers_left = 1;
		} else if len(head) >= 30 && head[0] == 1 && as_string(sub(head, 1, 7)) == "vorbis" {
			t.codec = .Vorbis;
			t.channels = cast(int)(head[11]);
			t.sample_rate = cast(int)(le32(sub_from(head, 12)));
			t.timescale = cast(s64)(t.sample_rate);
			t.extradata = clone_bytes(view(head));
			st.headers_left = 2; // OpusTags
		} else if len(head) >= 51 && head[0] == 0x7F && as_string(sub(head, 1, 5)) == "FLAC" {
			t.codec = .FLAC;
			t.extradata = clone_bytes(sub_from(head, 13)); // STREAMINFO metadata block
			si := sub_from(head, 17);
			t.sample_rate = cast(int)(be24(sub_from(si, 10)) >> 4);
			t.channels = cast(int)((si[12] >> 1) & 7) + 1;
			t.timescale = cast(s64)(t.sample_rate);
			st.headers_left = cast(int)(be16(sub_from(head, 7)));
		} else {
			st.headers_left = -1; // unknown stream: ignore forever
			return;
		}
		st.track = len(d.tracks);
		append(*d.tracks, t);
		d.ready = st.headers_left == 0;
		return;
	}
	if st.headers_left > 0 {
		st.headers_left -= 1;
		if st.headers_left == 0 { d.ready = true; }
		return;
	}
	if st.track < 0 { return; }
	t := *d.tracks[st.track];
	if t.codec == .Opus {
		toc: [2]u8;
		n := min(cast(int)(ref.size), 2);
		first := ifx ref.pieces > 0 then d.pieces[ref.piece_at].offset else ref.offset;
		read_full(d.src, first, sub(toc, 0, n));
		ref.dur = cast(s32)(opus_packet_samples(sub(toc, 0, n)));
	}
	ref.key = true;
	ref.pts = st.next_pts - cast(s64)(t.pre_skip);
	ref.dts = ref.pts;
	st.next_pts += cast(s64)(ref.dur);
	append(*st.pending, len(t.packets));
	append(*t.packets, ref);
}
#scope_export

