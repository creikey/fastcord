// Ogg pages -> logical-stream packets. Opus (voice messages), Vorbis and FLAC
// headers are recognized; packets spanning pages are recorded as pieces.

// Samples (48 kHz) in an Opus packet, from its TOC byte(s). RFC 6716 3.1.
opus_packet_samples :: (p: []u8) -> int {
	if p.count < 1 return 0;
	toc := p[0];
	cfg := toc >> 3;
	SILK :: int.[480, 960, 1920, 2880];
	CELT :: int.[120, 240, 480, 960];
	frame: int; // samples at 48 kHz
	if cfg < 12 frame = SILK[cfg & 3];
	else if cfg < 16 frame = ifx (cfg & 1) == 0 then 480 else 960;
	else frame = CELT[cfg & 3];
	count := 1;
	if (toc & 3) == {
	case 1; #through;
	case 2; count = 2;
	case 3;
		if p.count < 2 return 0;
		count = p[1] & 0x3f;
	}
	return frame * count;
}

#scope_module

ogg_init :: (d: *Demuxer) {
	d.format = .Ogg;
	d.state = New(Ogg);
	d.scan_proc = ogg_scan;
	d.free_proc = (d: *Demuxer) {
		o := cast(*Ogg) d.state;
		for o.streams {
			array_free(it.pending);
			array_free(it.cur_pieces);
		}
		array_free(o.streams);
		free(o);
	};
}

#scope_file

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

ogg_scan :: (d: *Demuxer) -> Scan_Status {
	o := cast(*Ogg) d.state;
	avail, complete := source_extent(d.src);
	need_data :: () #expand {
		if `complete `return .Done;
		reader_reset(*`d.reader);
		`return .Need_Data;
	}
	at := d.scan_pos;
	if at >= avail need_data();
	h, s := reader_peek(*d.reader, at, 27);
	if s != .Ok need_data();
	if str(h, 0, 4) != "OggS" {
		// resync
		d.scan_pos += 1;
		return .Progress;
	}
	granule := cast(s64) le64(h, 6);
	serial := le32(h, 14);
	nseg := cast(int) h[26];
	lacing, ls := reader_peek(*d.reader, at + 27, nseg);
	if ls != .Ok need_data();
	lac := array_copy(lacing,, temp);
	body_at := at + 27 + nseg;
	body_len: s64;
	for lac body_len += it;
	if body_at + body_len > avail need_data();

	st: *Ogg_Stream;
	for * o.streams if it.serial == serial st = it;
	if !st {
		st = array_add(*o.streams);
		st.* = .{serial = serial, track = -1};
	}
	st.pending.count = 0;

	pos := body_at;
	i := 0;
	while i < nseg {
		// gather segments of one packet within this page
		seg_start := pos;
		size: s64;
		done := false;
		while i < nseg {
			l := lac[i];
			size += l;
			i += 1;
			if l < 255 {
				done = true;
				break;
			}
		}
		pos += size;
		if size > 0 array_add(*st.cur_pieces, .{seg_start, cast(s32) size});
		st.cur_size += cast(s32) size;
		if !done break; // continues on next page
		finish_packet(d, st);
	}
	// granule = end position of the last packet completed on this page
	if granule >= 0 && st.pending.count > 0 && st.track >= 0 {
		t := *d.tracks[st.track];
		end := granule;
		for < st.pending {
			p := *t.packets[it];
			p.pts = end - p.dur - t.pre_skip;
			p.dts = p.pts;
			end -= p.dur;
		}
		st.next_pts = granule;
		t.duration = granule - t.pre_skip;
	}
	d.scan_pos = body_at + body_len;
	return .Progress;
}

finish_packet :: (d: *Demuxer, st: *Ogg_Stream) {
	defer {
		st.cur_size = 0;
		st.cur_pieces.count = 0;
	}
	if !st.cur_pieces.count return;
	ref := Packet_Ref.{offset = st.cur_pieces[0].offset, size = st.cur_size};
	if st.cur_pieces.count > 1 {
		ref.pieces = cast(s32) st.cur_pieces.count;
		ref.piece_at = cast(s32) d.pieces.count;
		array_add(*d.pieces, ..st.cur_pieces);
	}
	if st.track < 0 && st.headers_left == 0 {
		// first packet of the stream: identify codec
		head: [..]u8;
		head.allocator = temp;
		if demux_read(d, ref, *head) != .Ok return;
		t: Track;
		t.id = st.serial;
		t.kind = .Audio;
		if head.count >= 19 && str(head, 0, 8) == "OpusHead" {
			t.codec = .Opus;
			t.channels = head[9];
			t.pre_skip = le16(head, 10);
			t.sample_rate = 48000;
			t.timescale = 48000;
			t.extradata = array_copy(head);
			st.headers_left = 1;
		} else if head.count >= 30 && head[0] == 1 && str(head, 1, 6) == "vorbis" {
			t.codec = .Vorbis;
			t.channels = head[11];
			t.sample_rate = le32(head, 12);
			t.timescale = t.sample_rate;
			t.extradata = array_copy(head);
			st.headers_left = 2; // comment + setup headers
		} else if head.count >= 51 && head[0] == 0x7F && str(head, 1, 4) == "FLAC" {
			t.codec = .FLAC;
			t.extradata = array_copy(array_view(head, 13)); // STREAMINFO metadata block
			t.sample_rate = be24(head, 17 + 10) >> 4;
			t.channels = ((head[17 + 12] >> 1) & 7) + 1;
			t.timescale = t.sample_rate;
			st.headers_left = be16(head, 7);
		} else {
			st.headers_left = -1; // unknown stream: ignore forever
			return;
		}
		st.track = d.tracks.count;
		array_add(*d.tracks, t);
		d.ready = st.headers_left == 0;
		return;
	}
	if st.headers_left > 0 {
		st.headers_left -= 1;
		if st.headers_left == 0 d.ready = true;
		return;
	}
	if st.track < 0 return;
	t := *d.tracks[st.track];
	if t.codec == .Opus {
		toc: [2]u8;
		n := min(ref.size, 2);
		first := ifx ref.pieces > 0 then d.pieces[ref.piece_at].offset else ref.offset;
		read_full(d.src, first, array_view(toc, 0, n));
		ref.dur = cast(s32) opus_packet_samples(array_view(toc, 0, n));
	}
	ref.key = true;
	ref.pts = st.next_pts - t.pre_skip;
	ref.dts = ref.pts;
	st.next_pts += ref.dur;
	array_add(*st.pending, t.packets.count);
	array_add(*t.packets, ref);
}
