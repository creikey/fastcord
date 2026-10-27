// Matroska / WebM. Walks the EBML tree incrementally: Info and Tracks are read
// whole; Clusters are descended into and every (Simple)Block header is indexed
// (lacing resolved), payloads are not read during scanning.

#scope_module

mkv_init :: (d: *Demuxer) {
	d.format = .Matroska;
	m := New(Mkv);
	m.tc_scale = 1_000_000;
	m.seg_start = -1;
	d.state = m;
	d.scan_proc = mkv_scan;
	d.free_proc = (d: *Demuxer) {
		m := cast(*Mkv) d.state;
		deinit(*m.track_map);
		deinit(*m.default_dur);
		free(m);
	};
}

#scope_file

ID_EBML :: 0x1A45DFA3;
ID_SEGMENT :: 0x18538067;
ID_INFO :: 0x1549A966;
ID_TIMECODE_SCALE :: 0x2AD7B1;
ID_DURATION :: 0x4489;
ID_TRACKS :: 0x1654AE6B;
ID_TRACK_ENTRY :: 0xAE;
ID_TRACK_NUMBER :: 0xD7;
ID_TRACK_TYPE :: 0x83;
ID_CODEC_ID :: 0x86;
ID_CODEC_PRIVATE :: 0x63A2;
ID_CODEC_DELAY :: 0x56AA;
ID_DEFAULT_DURATION :: 0x23E383;
ID_VIDEO :: 0xE0;
ID_PIXEL_WIDTH :: 0xB0;
ID_PIXEL_HEIGHT :: 0xBA;
ID_AUDIO :: 0xE1;
ID_SAMPLING_FREQ :: 0xB5;
ID_CHANNELS :: 0x9F;
ID_BIT_DEPTH :: 0x6264;
ID_CLUSTER :: 0x1F43B675;
ID_CLUSTER_TIMECODE :: 0xE7;
ID_SIMPLE_BLOCK :: 0xA3;
ID_BLOCK_GROUP :: 0xA0;
ID_BLOCK :: 0xA1;
ID_BLOCK_DURATION :: 0x9B;
ID_REFERENCE_BLOCK :: 0xFB;

UNKNOWN_SIZE :: S64_MAX;

Mkv :: struct {
	seg_start: s64;
	seg_end: s64;
	tc_scale: s64; // ns per tick
	duration: float64; // in ticks
	have_tracks: bool;
	// cluster walk state
	in_cluster: bool;
	cluster_end: s64;
	cluster_tc: s64;
	track_map: Table(int, int); // track number -> index in d.tracks
	default_dur: Table(int, s64); // ns
}

// EBML variable-length integer. keep_marker for IDs.
vint :: (b: []u8, keep_marker: bool) -> s64, int, bool {
	if !b.count || b[0] == 0 return 0, 0, false;
	first := b[0];
	n := 1;
	mask: u8 = 0x80;
	while (first & mask) == 0 {
		n += 1;
		mask >>= 1;
	}
	if n > 8 || b.count < n return 0, 0, false;
	v := cast(s64) ifx keep_marker then first else (first & (mask - 1));
	all_ones := (first & (mask - 1)) == mask - 1;
	for i: 1..n - 1 {
		v = (v << 8) | b[i];
		if b[i] != 0xFF all_ones = false;
	}
	if !keep_marker && all_ones v = UNKNOWN_SIZE;
	return v, n, true;
}

Elem :: struct {
	id: s64;
	size: s64;
	hdr: int;
}

read_elem :: (d: *Demuxer, at: s64) -> Elem, Read_Status {
	b, s := reader_peek(*d.reader, at, 12);
	if s != .Ok {
		// near EOF: try smaller
		avail := source_extent(d.src);
		n := cast(int) min(avail - at, 12);
		if n < 2 return .{}, s;
		b, s = reader_peek(*d.reader, at, n);
		if s != .Ok return .{}, s;
	}
	id, n1, ok := vint(b, true);
	if !ok return .{}, .Error;
	size, n2, ok2 := vint(array_view(b, n1), false);
	if !ok2 return .{}, .Pending;
	return .{id, size, n1 + n2}, .Ok;
}

uint_of :: (b: []u8) -> s64 {
	v: s64;
	for b v = (v << 8) | it;
	return v;
}

float_of :: (b: []u8) -> float64 {
	if b.count == 4 { u := be32(b); return (cast(*float32) *u).*; }
	if b.count == 8 { u := be64(b); return (cast(*float64) *u).*; }
	return 0;
}

// Iterate elements in a fully-loaded buffer.
each :: (b: []u8, i: *int) -> s64, []u8, bool {
	if i.* >= b.count return 0, .[], false;
	id, n1, ok1 := vint(array_view(b, i.*), true);
	if !ok1 return 0, .[], false;
	size, n2, ok2 := vint(array_view(b, i.* + n1), false);
	if !ok2 return 0, .[], false;
	start := i.* + n1 + n2;
	end := ifx size == UNKNOWN_SIZE then b.count else min(start + size, b.count);
	i.* = end;
	return id, array_view(b, start, end - start), true;
}

mkv_scan :: (d: *Demuxer) -> Scan_Status {
	m := cast(*Mkv) d.state;
	avail, complete := source_extent(d.src);
	if m.seg_start < 0 {
		// EBML header then Segment
		e, s := read_elem(d, 0);
		if s != .Ok return ifx s == .Error then .Error else .Need_Data;
		if e.id != ID_EBML return .Error;
		at := e.hdr + e.size;
		seg, s2 := read_elem(d, at);
		if s2 != .Ok return ifx s2 == .Error then .Error else .Need_Data;
		if seg.id != ID_SEGMENT return .Error;
		m.seg_start = at + seg.hdr;
		m.seg_end = ifx seg.size == UNKNOWN_SIZE then S64_MAX else m.seg_start + seg.size;
		d.scan_pos = m.seg_start;
		return .Progress;
	}
	if d.scan_pos >= min(m.seg_end, avail) {
		if complete || d.scan_pos >= m.seg_end {
			m.in_cluster = false;
			return .Done;
		}
		reader_reset(*d.reader);
		return .Need_Data;
	}
	e, s := read_elem(d, d.scan_pos);
	if s != .Ok {
		if s == .Error return .Error;
		if complete return .Done;
		reader_reset(*d.reader);
		return .Need_Data;
	}
	body_at := d.scan_pos + e.hdr;

	if m.in_cluster {
		if d.scan_pos >= m.cluster_end || is_top_level(e.id) {
			m.in_cluster = false;
			return .Progress;
		}
		if e.id == {
		case ID_CLUSTER_TIMECODE;
			b, rs := reader_peek(*d.reader, body_at, e.size);
			if rs != .Ok return .Need_Data;
			m.cluster_tc = uint_of(b);
		case ID_SIMPLE_BLOCK;
			if body_at + e.size > avail return ifx complete then .Done else .Need_Data;
			index_block(d, m, body_at, e.size, true, -1, false);
		case ID_BLOCK_GROUP;
			if body_at + e.size > avail return ifx complete then .Done else .Need_Data;
			// find Block, BlockDuration, ReferenceBlock
			pos := body_at;
			end := body_at + e.size;
			blk_at: s64 = -1;
			blk_size: s64;
			dur: s64 = -1;
			has_ref := false;
			while pos < end {
				c, cs := read_elem(d, pos);
				if cs != .Ok break;
				cb := pos + c.hdr;
				if c.id == {
				case ID_BLOCK;
					blk_at, blk_size = cb, c.size;
				case ID_BLOCK_DURATION;
					b, rs := reader_peek(*d.reader, cb, c.size);
					if rs == .Ok dur = uint_of(b);
				case ID_REFERENCE_BLOCK;
					has_ref = true;
				}
				pos = cb + c.size;
			}
			if blk_at >= 0 index_block(d, m, blk_at, blk_size, false, dur, !has_ref);
		}
		d.scan_pos = body_at + (ifx e.size == UNKNOWN_SIZE then 0 else e.size);
		return .Progress;
	}

	if e.id == {
	case ID_INFO; #through;
	case ID_TRACKS;
		if e.size == UNKNOWN_SIZE return .Error;
		if body_at + e.size > avail return ifx complete then .Error else .Need_Data;
		body := NewArray(e.size, u8, initialized = false);
		defer array_free(body);
		if read_full(d.src, body_at, body) != .Ok return .Need_Data;
		if e.id == ID_INFO {
			parse_info(m, body);
		} else {
			parse_tracks(d, m, body);
			m.have_tracks = true;
		}
		d.scan_pos = body_at + e.size;
	case ID_CLUSTER;
		if !m.have_tracks return .Error;
		d.ready = true;
		m.in_cluster = true;
		m.cluster_end = ifx e.size == UNKNOWN_SIZE then S64_MAX else body_at + e.size;
		m.cluster_tc = 0;
		d.scan_pos = body_at;
	case;
		if e.size == UNKNOWN_SIZE return .Error;
		d.scan_pos = body_at + e.size;
	}
	return .Progress;
}

is_top_level :: (id: s64) -> bool {
	return id == ID_CLUSTER || id == ID_INFO || id == ID_TRACKS || id == 0x1C53BB6B || id == 0x1254C367 ||
		id == 0x1043A770 || id == 0x114D9B74 || id == 0x1941A469;
}

parse_info :: (m: *Mkv, b: []u8) {
	i := 0;
	while true {
		id, body, ok := each(b, *i);
		if !ok break;
		if id == ID_TIMECODE_SCALE m.tc_scale = max(uint_of(body), 1);
		else if id == ID_DURATION m.duration = float_of(body);
	}
}

parse_tracks :: (d: *Demuxer, m: *Mkv, b: []u8) {
	i := 0;
	while true {
		id, body, ok := each(b, *i);
		if !ok break;
		if id != ID_TRACK_ENTRY continue;
		t: Track;
		t.timescale = 1_000_000_000 / m.tc_scale;
		t.duration = cast(s64) m.duration;
		codec_id: string;
		codec_delay_ns: s64;
		j := 0;
		while true {
			cid, cb, cok := each(body, *j);
			if !cok break;
			if cid == {
			case ID_TRACK_NUMBER; t.id = uint_of(cb);
			case ID_TRACK_TYPE;
				v := uint_of(cb);
				if v == 1 t.kind = .Video;
				else if v == 2 t.kind = .Audio;
			case ID_CODEC_ID; codec_id = to_string(cb.data, cb.count);
			case ID_CODEC_PRIVATE; t.extradata = array_copy(cb);
			case ID_CODEC_DELAY; codec_delay_ns = uint_of(cb);
			case ID_DEFAULT_DURATION; table_set(*m.default_dur, t.id, uint_of(cb));
			case ID_VIDEO;
				k := 0;
				while true {
					vid, vb, vok := each(cb, *k);
					if !vok break;
					if vid == ID_PIXEL_WIDTH t.width = uint_of(vb);
					if vid == ID_PIXEL_HEIGHT t.height = uint_of(vb);
				}
			case ID_AUDIO;
				k := 0;
				while true {
					aid, ab, aok := each(cb, *k);
					if !aok break;
					if aid == {
					case ID_SAMPLING_FREQ; t.sample_rate = cast(int) float_of(ab);
					case ID_CHANNELS; t.channels = uint_of(ab);
					case ID_BIT_DEPTH; t.bits = uint_of(ab);
					}
				}
			}
		}
		// codec_id is a view into body; resolve before body goes away
		if codec_id == {
		case "V_MPEG4/ISO/AVC"; t.codec = .H264;
		case "V_MPEGH/ISO/HEVC"; t.codec = .HEVC;
		case "V_VP8"; t.codec = .VP8;
		case "V_VP9"; t.codec = .VP9;
		case "V_AV1"; t.codec = .AV1;
		case "A_OPUS";
			t.codec = .Opus;
			t.pre_skip = ifx t.extradata.count >= 12 then cast(int) le16(t.extradata, 10) else codec_delay_ns * 48000 / 1_000_000_000;
		case "A_VORBIS"; t.codec = .Vorbis;
		case "A_FLAC"; t.codec = .FLAC;
		case "A_MPEG/L3"; t.codec = .MP3;
		case "A_PCM/INT/LIT"; t.codec = .PCM;
		case "A_PCM/INT/BIG"; t.codec = .PCM; t.pcm_big = true;
		case "A_PCM/FLOAT/IEEE"; t.codec = .PCM; t.pcm_float = true;
		case;
			if begins_with(codec_id, "A_AAC") {
				t.codec = .AAC;
				t.aac_asc = array_copy(t.extradata);
			}
		}
		if t.codec == .FLAC && t.extradata.count > 4 && str(t.extradata, 0, 4) == "fLaC" {
			// keep metadata blocks only, like MP4 dfLa
			nb := array_copy(array_view(t.extradata, 4));
			array_free(t.extradata);
			t.extradata = nb;
		}
		table_set(*m.track_map, t.id, d.tracks.count);
		array_add(*d.tracks, t);
	}
}

index_block :: (d: *Demuxer, m: *Mkv, at: s64, size: s64, simple: bool, block_dur: s64, group_key: bool) {
	hb, s := reader_peek(*d.reader, at, min(size, 64));
	if s != .Ok return;
	tn, n, ok := vint(hb, false);
	if !ok || hb.count < n + 3 return;
	has, ti := table_find(*m.track_map, tn);
	if !has return;
	t := *d.tracks[ti];
	rel := cast(s64) cast(s16) be16(hb, n);
	flags := hb[n + 2];
	key := ifx simple then (flags & 0x80) != 0 else group_key;
	if t.kind == .Audio key = true;
	pts := m.cluster_tc + rel;
	hdr := n + 3;
	lacing := (flags >> 1) & 3;
	payload_at := at + hdr;
	payload_size := size - hdr;
	dur := cast(s32) block_dur;
	if dur <= 0 {
		okd, dd := table_find(*m.default_dur, t.id);
		if okd dur = cast(s32) (dd / m.tc_scale);
	}
	if lacing == 0 {
		array_add(*t.packets, .{offset = payload_at, size = cast(s32) payload_size, pts = pts, dts = pts, dur = dur, key = key});
		return;
	}
	// Laced: frame count, then sizes
	lb, ls := reader_peek(*d.reader, payload_at, min(payload_size, 4096));
	if ls != .Ok || lb.count < 1 return;
	count := cast(int) lb[0] + 1;
	sizes := NewArray(count, s64,, temp);
	p := 1;
	if lacing == {
	case 1; // Xiph
		for k: 0..count - 2 {
			v: s64;
			while p < lb.count {
				c := lb[p];
				p += 1;
				v += c;
				if c != 255 break;
			}
			sizes[k] = v;
		}
	case 3; // EBML
		first, fn, fok := vint(array_view(lb, p), false);
		if !fok return;
		p += fn;
		sizes[0] = first;
		for k: 1..count - 2 {
			raw, rn, rok := vint(array_view(lb, p), false);
			if !rok return;
			p += rn;
			bias := (1 << (7 * rn - 1)) - 1;
			sizes[k] = sizes[k - 1] + (raw - bias);
		}
	case 2; // fixed
		each_size := (payload_size - 1) / count;
		for * sizes it.* = each_size;
	}
	total: s64;
	for k: 0..count - 2 total += sizes[k];
	if lacing != 2 sizes[count - 1] = payload_size - p - total;
	for sizes if it < 0 || it > payload_size return;
	off := payload_at + p;
	frame_dur := ifx dur > 0 then dur / cast(s32) count else 0;
	for sizes {
		array_add(*t.packets, .{offset = off, size = cast(s32) it, pts = pts + frame_dur * it_index, dts = pts, dur = frame_dur, key = key});
		off += it;
	}
}
