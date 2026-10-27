// Container demuxing (all formats written here, no libraries).
//
// Every demuxer builds a per-track packet index (offset/size/pts/key) as data
// becomes available: demux_scan() extends it incrementally, so a file that is
// still downloading becomes playable as soon as its headers (and first
// packets) arrive. Reading a packet is then a random-access read of the source.

Format :: enum u8 { Unknown; MP4; Matroska; Ogg; MP3; WAV; FLAC; }

Codec :: enum u8 {
	Unknown;
	// video
	H264; HEVC; VP8; VP9; AV1;
	// audio
	AAC; MP3; Opus; Vorbis; FLAC; PCM;
}

Track_Kind :: enum u8 { Other; Video; Audio; }

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

// Buffered random-access reader for scanning (64 KiB window).
Buf_Reader :: struct {
	src: *Byte_Source;
	buf: []u8;
	start: s64;
	len: int;
}

// Detect the format and set up a demuxer. Returns null + .Need_Data if not
// enough bytes are available yet to detect (retry later).
demux_open :: (src: *Byte_Source) -> *Demuxer, Scan_Status {
	head: [64]u8;
	avail, complete := source_extent(src);
	n := cast(int) min(avail, 64);
	if n < 12 && !complete return null, .Need_Data;
	h := array_view(head, 0, n);
	if read_full(src, 0, h) != .Ok return null, .Need_Data;
	d := New(Demuxer);
	d.src = src;
	d.reader = .{src = src, buf = NewArray(64 * 1024, u8), start = -1};
	box := ifx n >= 8 then str(h, 4, 4) else "";
	if box == "ftyp" || box == "moov" || box == "mdat" || box == "free" || box == "wide" || box == "styp" {
		mp4_init(d);
	} else if n >= 4 && h[0] == 0x1A && h[1] == 0x45 && h[2] == 0xDF && h[3] == 0xA3 {
		mkv_init(d);
	} else if n >= 4 && str(h, 0, 4) == "OggS" {
		ogg_init(d);
	} else if n >= 12 && str(h, 0, 4) == "RIFF" && str(h, 8, 4) == "WAVE" {
		wav_init(d);
	} else if n >= 4 && str(h, 0, 4) == "fLaC" {
		flac_init(d);
	} else if n >= 3 && (str(h, 0, 3) == "ID3" || (h[0] == 0xFF && (h[1] & 0xE0) == 0xE0)) {
		mp3_init(d);
	} else {
		array_free(d.reader.buf);
		free(d);
		return null, .Error;
	}
	return d, .Progress;
}

// Extend the index. Cheap to call repeatedly; returns .Done once complete.
demux_scan :: (d: *Demuxer) -> Scan_Status {
	if d.failed return .Error;
	if d.complete return .Done;
	s := d.scan_proc(d);
	if s == .Done {
		d.complete = true;
		d.ready = true;
		finalize_tracks(d);
	} else if s == .Error {
		d.failed = true;
	}
	return s;
}

// Scan until ready (headers parsed) or blocked/failed.
demux_scan_headers :: (d: *Demuxer) -> Scan_Status {
	while !d.ready {
		s := demux_scan(d);
		if s != .Progress return s;
	}
	return .Progress;
}

// Scan everything available.
demux_scan_all :: (d: *Demuxer) -> Scan_Status {
	s := demux_scan(d);
	while s == .Progress s = demux_scan(d);
	return s;
}

demux_destroy :: (d: *Demuxer) {
	if !d return;
	if d.free_proc d.free_proc(d);
	for d.tracks {
		array_free(it.extradata);
		array_free(it.aac_asc);
		array_free(it.packets);
	}
	array_free(d.tracks);
	array_free(d.pieces);
	array_free(d.reader.buf);
	free(d);
}

// Read packet payload into buf (resized). .Pending if not downloaded yet.
demux_read :: (d: *Demuxer, p: Packet_Ref, buf: *[..]u8) -> Read_Status {
	array_resize(buf, p.size, initialize = false);
	if p.pieces == 0 return read_full(d.src, p.offset, buf.*);
	at := 0;
	for i: 0..p.pieces - 1 {
		pc := d.pieces[p.piece_at + i];
		s := read_full(d.src, pc.offset, array_view(buf.*, at, pc.size));
		if s != .Ok return s;
		at += pc.size;
	}
	return .Ok;
}

// Index of the last keyframe whose pts <= t (ticks), or 0.
demux_find_keyframe :: (t: *Track, ticks: s64) -> int {
	best := 0;
	for t.packets {
		if it.key && it.pts <= ticks best = it_index;
		if it.dts > ticks + t.timescale * 10 break; // far past: stop (index is in dts order)
	}
	return best;
}

track_seconds :: inline (t: *Track, ticks: s64) -> float64 {
	return cast(float64) ticks / cast(float64) max(t.timescale, 1);
}

track_ticks :: inline (t: *Track, seconds: float64) -> s64 {
	return cast(s64) (seconds * cast(float64) t.timescale);
}

// Longest track duration in seconds (0 if unknown).
demux_duration :: (d: *Demuxer) -> float64 {
	best: float64;
	for * d.tracks if it.kind != .Other best = max(best, track_seconds(it, it.duration));
	return best;
}

demux_track :: (d: *Demuxer, kind: Track_Kind) -> int {
	for d.tracks if it.kind == kind && it.codec != .Unknown return it_index;
	return -1;
}

// Byte helpers: big/little endian at b[i].
be16 :: inline (b: []u8, i := 0) -> u16 { return ((cast(u16) b[i]) << 8) | b[i + 1]; }
be24 :: inline (b: []u8, i := 0) -> u32 { return ((cast(u32) b[i]) << 16) | ((cast(u32) b[i + 1]) << 8) | b[i + 2]; }
be32 :: inline (b: []u8, i := 0) -> u32 { return ((cast(u32) b[i]) << 24) | ((cast(u32) b[i + 1]) << 16) | ((cast(u32) b[i + 2]) << 8) | b[i + 3]; }
be64 :: inline (b: []u8, i := 0) -> u64 { return ((cast(u64) be32(b, i)) << 32) | be32(b, i + 4); }
le16 :: inline (b: []u8, i := 0) -> u16 { return b[i] | ((cast(u16) b[i + 1]) << 8); }
le32 :: inline (b: []u8, i := 0) -> u32 { return b[i] | ((cast(u32) b[i + 1]) << 8) | ((cast(u32) b[i + 2]) << 16) | ((cast(u32) b[i + 3]) << 24); }
le64 :: inline (b: []u8, i := 0) -> u64 { return le32(b, i) | ((cast(u64) le32(b, i + 4)) << 32); }

#scope_module

// n bytes at b[i] as a string (no copy).
str :: inline (b: []u8, i: int, n: int) -> string { return to_string(b.data + i, n); }

finalize_tracks :: (d: *Demuxer) {
	for * t: d.tracks {
		if !t.packets.count continue;
		// Fill missing durations from the next packet in pts order.
		ord := NewArray(t.packets.count, int,, temp);
		for * ord it.* = it_index;
		// insertion sort: nearly sorted (B-frame reorder depth is small)
		pk := t.packets;
		for i: 1..ord.count - 1 {
			v := ord[i];
			j := i - 1;
			while j >= 0 && pk[ord[j]].pts > pk[v].pts {
				ord[j + 1] = ord[j];
				j -= 1;
			}
			ord[j + 1] = v;
		}
		for k: 0..ord.count - 2 {
			p := *pk[ord[k]];
			if p.dur <= 0 p.dur = cast(s32) (pk[ord[k + 1]].pts - p.pts);
		}
		last := *pk[ord[ord.count - 1]];
		if last.dur <= 0 && ord.count > 1 last.dur = pk[ord[ord.count - 2]].dur;
		end := last.pts + max(last.dur, 0);
		if t.duration <= 0 || end > t.duration t.duration = end;
	}
}

// Returns a view of n bytes at offset (n <= 64 KiB), or a status.
reader_peek :: (r: *Buf_Reader, offset: s64, n: int) -> []u8, Read_Status {
	assert(n <= r.buf.count);
	if r.start >= 0 && offset >= r.start && offset + n <= r.start + r.len {
		return array_view(r.buf, offset - r.start, n), .Ok;
	}
	got := 0;
	status := Read_Status.Ok;
	while got < r.buf.count {
		k, s := r.src.read_at(r.src.user, offset + got, array_view(r.buf, got));
		got += k;
		if s != .Ok || k == 0 {
			status = ifx s == .Ok then .Pending else s;
			break;
		}
	}
	r.start = offset;
	r.len = got;
	if got < n return .[], ifx status == .Ok then .Pending else status;
	return array_view(r.buf, 0, n), .Ok;
}

// Invalidate cached bytes (a growing source may have filled the tail).
reader_reset :: (r: *Buf_Reader) { r.start = -1; r.len = 0; }
