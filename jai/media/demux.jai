// Container demuxing (all formats written here, no libraries).
//
// Every demuxer builds a per-track packet index (offset/size/pts/key) as data
// becomes available: demux_scan() extends it incrementally, so a file that is
// still downloading becomes playable as soon as its headers (and first
// packets) arrive. Reading a packet is then a random-access read of the source.


Format :: enum u8 {Unknown; MP4; Matroska; Ogg; MP3; WAV; FLAC;}

Codec :: enum u8 {
	Unknown;
	// video
	H264; HEVC; VP8; VP9; AV1;
	// audio
	AAC; MP3; Opus; Vorbis; FLAC; PCM;
}

Track_Kind :: enum u8 {Other; Video; Audio;}

Track :: struct {
	id: int; // container track id/number
	kind: Track_Kind;
	codec: Codec;
	timescale: s64; // ticks per second for pts/dts/dur
	duration: s64; // ticks; 0 = unknown
	// video
	width: int;
	height: int;
	// audio
	sample_rate: int;
	channels: int;
	bits: int; // PCM bits per sample
	pcm_float: bool;
	pcm_big: bool;
	pre_skip: int; // Opus pre-skip (48 kHz samples), decoders drop these
	// Codec config: avcC/hvcC/vpcC(with version+flags)/av1C box payload, AAC esds
	// (ES_Descriptor) or AudioSpecificConfig, OpusHead, FLAC STREAMINFO block.
	extradata: []u8;
	aac_asc: []u8; // AudioSpecificConfig if known
	packets: [..]Packet_Ref; // in decode order
}

Packet_Ref :: struct {
	offset: s64;
	size: s32;
	pieces: s32; // >0: count of pieces at piece_at (non-contiguous, e.g. Ogg)
	piece_at: s32;
	pts: s64;
	dts: s64;
	dur: s32;
	key: bool;
}

Piece :: struct {
	offset: s64;
	size: s32;
}

Scan_Status :: enum u8 {
	Progress; // made progress; call again
	Need_Data; // waiting for the source to grow
	Done; // index complete
	Error;
}

Demuxer :: struct {
	src: *Byte_Source;
	format: Format;
	tracks: [..]Track;
	pieces: [..]Piece;
	ready: bool; // headers parsed: tracks known, playback can start
	complete: bool; // index complete
	failed: bool;
	scan_pos: s64;
	state: *void;
	scan_proc: (d: *Demuxer) -> Scan_Status;
	free_proc: (d: *Demuxer);
	reader: Buf_Reader;
}

// Detect the format and set up a demuxer. Returns nil + .Need_Data if not
// enough bytes are available yet to detect (retry later).
demux_open :: (src: *Byte_Source) -> *Demuxer, Scan_Status {
	head: [64]u8;
	avail, complete := source_extent(src);
	n := cast(int)(min(avail, 64));
	if n < 12 && !complete { return null, .Need_Data; }
	if read_full(src, 0, sub(head, 0, n)) != .Ok { return null, .Need_Data; }
	h := sub(head, 0, n);
	d := new(Demuxer);
	d.src = src;
	buf_reader_init(*d.reader, src);
	if len(h) >= 8 && (as_string(sub(h, 4, 8)) == "ftyp" || as_string(sub(h, 4, 8)) == "moov" || as_string(sub(h, 4, 8)) == "mdat" || as_string(sub(h, 4, 8)) == "free" || as_string(sub(h, 4, 8)) == "wide" || as_string(sub(h, 4, 8)) == "styp") {
		mp4_init(d);
	} else if len(h) >= 4 && h[0] == 0x1A && h[1] == 0x45 && h[2] == 0xDF && h[3] == 0xA3 {
		mkv_init(d);
	} else if len(h) >= 4 && as_string(sub(h, 0, 4)) == "OggS" {
		ogg_init(d);
	} else if len(h) >= 12 && as_string(sub(h, 0, 4)) == "RIFF" && as_string(sub(h, 8, 12)) == "WAVE" {
		wav_init(d);
	} else if len(h) >= 4 && as_string(sub(h, 0, 4)) == "fLaC" {
		flac_init(d);
	} else if len(h) >= 3 && (as_string(sub(h, 0, 3)) == "ID3" || (h[0] == 0xFF && (h[1] & 0xE0) == 0xE0)) {
		mp3_init(d);
	} else {
		free(d);
		return null, .Error;
	}
	return d, .Progress;
}

// Extend the index. Cheap to call repeatedly; returns .Done once complete.
demux_scan :: (d: *Demuxer) -> Scan_Status {
	if d.failed { return .Error; }
	if d.complete { return .Done; }
	s := d.scan_proc(d);
	if s == {
	case .Done;
		d.complete = true;
		d.ready = true;
		finalize_tracks(d);
	case .Error;
		d.failed = true;
	case .Progress; #through; case .Need_Data;
	}
	return s;
}

// Scan until ready (headers parsed) or blocked/failed.
demux_scan_headers :: (d: *Demuxer) -> Scan_Status {
	while !d.ready {
		s := demux_scan(d);
		if s != .Progress { return s; }
	}
	return .Progress;
}

// Scan everything available.
demux_scan_all :: (d: *Demuxer) -> Scan_Status {
	while true {
		s := demux_scan(d);
		if s != .Progress { return s; }
	}
}

demux_destroy :: (d: *Demuxer) {
	if d == null { return; }
	if d.free_proc != null { d.free_proc(d); }
	for * t: d.tracks {
		delete(t.extradata);
		delete(t.aac_asc);
		delete(t.packets);
	}
	delete(d.tracks);
	delete(d.pieces);
	buf_reader_destroy(*d.reader);
	free(d);
}

// Read packet payload into buf (resized). .Pending if not downloaded yet.
demux_read :: (d: *Demuxer, p: Packet_Ref, buf: *[..]u8) -> Read_Status {
	resize(buf, cast(int)(p.size));
	if p.pieces == 0 {
		return read_full(d.src, p.offset, buf.*);
	}
	at := 0;
	for i: 0..cast(int)(p.pieces)-1 {
		pc := d.pieces[cast(int)(p.piece_at) + i];
		{ s := read_full(d.src, pc.offset, sub(sub_from(buf.*, at), 0, pc.size));
		if s != .Ok { return s; } }
		at += cast(int)(pc.size);
	}
	return .Ok;
}

// Index of the last keyframe whose pts <= t (ticks), or 0.
demux_find_keyframe :: (t: *Track, ticks: s64) -> int {
	best := 0;
	for p, i: t.packets {
		if p.key && p.pts <= ticks { best = i; }
		if p.dts > ticks + t.timescale * 10 { break; } // far past: stop (index is in dts order)
	}
	return best;
}

track_seconds :: inline (t: *Track, ticks: s64) -> float64 {
	return cast(float64)(ticks) / cast(float64)(max(t.timescale, 1));
};

track_ticks :: inline (t: *Track, seconds: float64) -> s64 {
	return cast(s64)(seconds * cast(float64)(t.timescale));
};

// Longest track duration in seconds (0 if unknown).
demux_duration :: (d: *Demuxer) -> float64 {
	best: float64;
	for * t: d.tracks {
		if t.kind == .Other { continue; }
		best = max(best, track_seconds(t, t.duration));
	}
	return best;
}

demux_track :: (d: *Demuxer, kind: Track_Kind) -> int {
	for t, i: d.tracks {
		if t.kind == kind && t.codec != .Unknown { return i; }
	}
	return -1;
}
#scope_module

finalize_tracks :: (d: *Demuxer) {
	for * t: d.tracks {
		if len(t.packets) == 0 { continue; }
		// Fill missing durations from the next packet in pts order.
		ord := make_slice(int, len(t.packets), temp);
		for i: 0..len(ord)-1 { ord[i] = i; }
		sort_by_pts(ord, view(t.packets));
		for k: 0..cast(int)((len(ord) - 1))-1 {
			p := *t.packets[ord[k]];
			if p.dur <= 0 { p.dur = cast(s32)(t.packets[ord[k + 1]].pts - p.pts); }
		}
		last := *t.packets[ord[len(ord) - 1]];
		if last.dur <= 0 && len(ord) > 1 { last.dur = t.packets[ord[len(ord) - 2]].dur; }
		end := last.pts + cast(s64)(max(last.dur, 0));
		if t.duration <= 0 || end > t.duration { t.duration = end; }
	}
}

sort_by_pts :: (ord: []int, pk: []Packet_Ref) {
	// insertion sort: nearly sorted (B-frame reorder depth is small)
	for i: 1..len(ord)-1 {
		v := ord[i];
		j := i - 1;
		while j >= 0 && pk[ord[j]].pts > pk[v].pts {
			ord[j + 1] = ord[j];
			j -= 1;
		}
		ord[j + 1] = v;
	}
}
#scope_export

// ---------------------------------------------------------------------------
// Buffered random-access reader for scanning (64 KiB window).

Buf_Reader :: struct {
	src: *Byte_Source;
	buf: []u8;
	start: s64;
	len: int;
}
#scope_module

buf_reader_init :: (r: *Buf_Reader, src: *Byte_Source) {
	r.src = src;
	r.buf = make_slice(u8, 64 * 1024);
	r.start = -1;
}

buf_reader_destroy :: (r: *Buf_Reader) {
	delete(r.buf);
}

// Returns a view of n bytes at offset (n <= 64 KiB), or a status.
peek :: (r: *Buf_Reader, offset: s64, n: int) -> []u8, Read_Status {
	assert(n <= len(r.buf));
	if r.start >= 0 && offset >= r.start && offset + cast(s64)(n) <= r.start + cast(s64)(r.len) {
		o := cast(int)(offset - r.start);
		return sub(sub_from(r.buf, o), 0, n), .Ok;
	}
	got := 0;
	status := Read_Status.Ok;
	while got < len(r.buf) {
		k, s := r.src.read_at(r.src.user, offset + cast(s64)(got), sub_from(r.buf, got));
		got += k;
		if s != .Ok || k == 0 {
			status = ifx s == .Ok then .Pending else s;
			break;
		}
	}
	r.start = offset;
	r.len = got;
	if got < n { return .{}, ifx status == .Ok then .Pending else status; }
	return sub(r.buf, 0, n), .Ok;
}

// Invalidate cached bytes (a growing source may have filled the tail).
reader_reset :: (r: *Buf_Reader) {r.start = -1; r.len = 0;}
#scope_export

// ---------------------------------------------------------------------------
// Byte helpers

be16 :: inline (b: []u8) -> u16 {return ((cast(u16) b[0]) << 8) | (cast(u16) b[1]);};
be24 :: inline (b: []u8) -> u32 {return ((cast(u32) b[0]) << 16) | ((cast(u32) b[1]) << 8) | (cast(u32) b[2]);};
be32 :: inline (b: []u8) -> u32 {return ((cast(u32) b[0]) << 24) | ((cast(u32) b[1]) << 16) | ((cast(u32) b[2]) << 8) | (cast(u32) b[3]);};
be64 :: inline (b: []u8) -> u64 {return ((cast(u64) be32(b)) << 32) | (cast(u64) be32(sub_from(b, 4)));};
le16 :: inline (b: []u8) -> u16 {return (cast(u16) b[0]) | ((cast(u16) b[1]) << 8);};
le32 :: inline (b: []u8) -> u32 {return (cast(u32) b[0]) | ((cast(u32) b[1]) << 8) | ((cast(u32) b[2]) << 16) | ((cast(u32) b[3]) << 24);};
le64 :: inline (b: []u8) -> u64 {return (cast(u64) le32(b)) | ((cast(u64) le32(sub_from(b, 4))) << 32);};
#scope_module

clone_bytes :: (b: []u8) -> []u8 {
	out := make_slice(u8, len(b));
	copy(out, b);
	return out;
}
#scope_export

