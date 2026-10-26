package media

// Container demuxing (all formats written here, no libraries).
//
// Every demuxer builds a per-track packet index (offset/size/pts/key) as data
// becomes available: demux_scan() extends it incrementally, so a file that is
// still downloading becomes playable as soon as its headers (and first
// packets) arrive. Reading a packet is then a random-access read of the source.


Format :: enum u8 {Unknown, MP4, Matroska, Ogg, MP3, WAV, FLAC}

Codec :: enum u8 {
	Unknown,
	// video
	H264, HEVC, VP8, VP9, AV1,
	// audio
	AAC, MP3, Opus, Vorbis, FLAC, PCM,
}

Track_Kind :: enum u8 {Other, Video, Audio}

Track :: struct {
	id:           int, // container track id/number
	kind:         Track_Kind,
	codec:        Codec,
	timescale:    i64, // ticks per second for pts/dts/dur
	duration:     i64, // ticks; 0 = unknown
	// video
	width:        int,
	height:       int,
	// audio
	sample_rate:  int,
	channels:     int,
	bits:         int, // PCM bits per sample
	pcm_float:    bool,
	pcm_big:      bool,
	pre_skip:     int, // Opus pre-skip (48 kHz samples), decoders drop these
	// Codec config: avcC/hvcC/vpcC(with version+flags)/av1C box payload, AAC esds
	// (ES_Descriptor) or AudioSpecificConfig, OpusHead, FLAC STREAMINFO block.
	extradata:    []u8,
	aac_asc:      []u8, // AudioSpecificConfig if known
	packets:      [dynamic]Packet_Ref, // in decode order
}

Packet_Ref :: struct {
	offset:  i64,
	size:    i32,
	pieces:  i32, // >0: count of pieces at piece_at (non-contiguous, e.g. Ogg)
	piece_at: i32,
	pts:     i64,
	dts:     i64,
	dur:     i32,
	key:     bool,
}

Piece :: struct {
	offset: i64,
	size:   i32,
}

Scan_Status :: enum u8 {
	Progress, // made progress; call again
	Need_Data, // waiting for the source to grow
	Done, // index complete
	Error,
}

Demuxer :: struct {
	src:        ^Byte_Source,
	format:     Format,
	tracks:     [dynamic]Track,
	pieces:     [dynamic]Piece,
	ready:      bool, // headers parsed: tracks known, playback can start
	complete:   bool, // index complete
	failed:     bool,
	scan_pos:   i64,
	state:      rawptr,
	scan_proc:  proc(d: ^Demuxer) -> Scan_Status,
	free_proc:  proc(d: ^Demuxer),
	reader:     Buf_Reader,
}

// Detect the format and set up a demuxer. Returns nil + .Need_Data if not
// enough bytes are available yet to detect (retry later).
demux_open :: proc(src: ^Byte_Source) -> (^Demuxer, Scan_Status) {
	head: [64]u8
	avail, complete := source_extent(src)
	n := int(min(avail, 64))
	if n < 12 && !complete do return nil, .Need_Data
	if read_full(src, 0, head[:n]) != .Ok do return nil, .Need_Data
	h := head[:n]
	d := new(Demuxer)
	d.src = src
	buf_reader_init(&d.reader, src)
	switch {
	case len(h) >= 8 && (string(h[4:8]) == "ftyp" || string(h[4:8]) == "moov" || string(h[4:8]) == "mdat" || string(h[4:8]) == "free" || string(h[4:8]) == "wide" || string(h[4:8]) == "styp"):
		mp4_init(d)
	case len(h) >= 4 && h[0] == 0x1A && h[1] == 0x45 && h[2] == 0xDF && h[3] == 0xA3:
		mkv_init(d)
	case len(h) >= 4 && string(h[:4]) == "OggS":
		ogg_init(d)
	case len(h) >= 12 && string(h[:4]) == "RIFF" && string(h[8:12]) == "WAVE":
		wav_init(d)
	case len(h) >= 4 && string(h[:4]) == "fLaC":
		flac_init(d)
	case len(h) >= 3 && (string(h[:3]) == "ID3" || (h[0] == 0xFF && h[1] & 0xE0 == 0xE0)):
		mp3_init(d)
	case:
		free(d)
		return nil, .Error
	}
	return d, .Progress
}

// Extend the index. Cheap to call repeatedly; returns .Done once complete.
demux_scan :: proc(d: ^Demuxer) -> Scan_Status {
	if d.failed do return .Error
	if d.complete do return .Done
	s := d.scan_proc(d)
	switch s {
	case .Done:
		d.complete = true
		d.ready = true
		finalize_tracks(d)
	case .Error:
		d.failed = true
	case .Progress, .Need_Data:
	}
	return s
}

// Scan until ready (headers parsed) or blocked/failed.
demux_scan_headers :: proc(d: ^Demuxer) -> Scan_Status {
	for !d.ready {
		s := demux_scan(d)
		if s != .Progress do return s
	}
	return .Progress
}

// Scan everything available.
demux_scan_all :: proc(d: ^Demuxer) -> Scan_Status {
	for {
		s := demux_scan(d)
		if s != .Progress do return s
	}
}

demux_destroy :: proc(d: ^Demuxer) {
	if d == nil do return
	if d.free_proc != nil do d.free_proc(d)
	for &t in d.tracks {
		delete(t.extradata)
		delete(t.aac_asc)
		delete(t.packets)
	}
	delete(d.tracks)
	delete(d.pieces)
	buf_reader_destroy(&d.reader)
	free(d)
}

// Read packet payload into buf (resized). .Pending if not downloaded yet.
demux_read :: proc(d: ^Demuxer, p: Packet_Ref, buf: ^[dynamic]u8) -> Read_Status {
	resize(buf, int(p.size))
	if p.pieces == 0 {
		return read_full(d.src, p.offset, buf[:])
	}
	at := 0
	for i in 0 ..< int(p.pieces) {
		pc := d.pieces[int(p.piece_at) + i]
		if s := read_full(d.src, pc.offset, buf[at:][:pc.size]); s != .Ok do return s
		at += int(pc.size)
	}
	return .Ok
}

// Index of the last keyframe whose pts <= t (ticks), or 0.
demux_find_keyframe :: proc(t: ^Track, ticks: i64) -> int {
	best := 0
	for p, i in t.packets {
		if p.key && p.pts <= ticks do best = i
		if p.dts > ticks + t.timescale * 10 do break // far past: stop (index is in dts order)
	}
	return best
}

track_seconds :: #force_inline proc(t: ^Track, ticks: i64) -> f64 {
	return f64(ticks) / f64(max(t.timescale, 1))
}

track_ticks :: #force_inline proc(t: ^Track, seconds: f64) -> i64 {
	return i64(seconds * f64(t.timescale))
}

// Longest track duration in seconds (0 if unknown).
demux_duration :: proc(d: ^Demuxer) -> f64 {
	best: f64
	for &t in d.tracks {
		if t.kind == .Other do continue
		best = max(best, track_seconds(&t, t.duration))
	}
	return best
}

demux_track :: proc(d: ^Demuxer, kind: Track_Kind) -> int {
	for t, i in d.tracks {
		if t.kind == kind && t.codec != .Unknown do return i
	}
	return -1
}

@(private)
finalize_tracks :: proc(d: ^Demuxer) {
	for &t in d.tracks {
		if len(t.packets) == 0 do continue
		// Fill missing durations from the next packet in pts order.
		ord := make([]int, len(t.packets), context.temp_allocator)
		for i in 0 ..< len(ord) do ord[i] = i
		sort_by_pts(ord, t.packets[:])
		for k in 0 ..< len(ord) - 1 {
			p := &t.packets[ord[k]]
			if p.dur <= 0 do p.dur = i32(t.packets[ord[k + 1]].pts - p.pts)
		}
		last := &t.packets[ord[len(ord) - 1]]
		if last.dur <= 0 && len(ord) > 1 do last.dur = t.packets[ord[len(ord) - 2]].dur
		end := last.pts + i64(max(last.dur, 0))
		if t.duration <= 0 || end > t.duration do t.duration = end
	}
}

@(private)
sort_by_pts :: proc(ord: []int, pk: []Packet_Ref) {
	// insertion sort: nearly sorted (B-frame reorder depth is small)
	for i in 1 ..< len(ord) {
		v := ord[i]
		j := i - 1
		for j >= 0 && pk[ord[j]].pts > pk[v].pts {
			ord[j + 1] = ord[j]
			j -= 1
		}
		ord[j + 1] = v
	}
}

// ---------------------------------------------------------------------------
// Buffered random-access reader for scanning (64 KiB window).

Buf_Reader :: struct {
	src:   ^Byte_Source,
	buf:   []u8,
	start: i64,
	len:   int,
}

@(private)
buf_reader_init :: proc(r: ^Buf_Reader, src: ^Byte_Source) {
	r.src = src
	r.buf = make([]u8, 64 * 1024)
	r.start = -1
}

@(private)
buf_reader_destroy :: proc(r: ^Buf_Reader) {
	delete(r.buf)
}

// Returns a view of n bytes at offset (n <= 64 KiB), or a status.
@(private)
peek :: proc(r: ^Buf_Reader, offset: i64, n: int) -> ([]u8, Read_Status) {
	assert(n <= len(r.buf))
	if r.start >= 0 && offset >= r.start && offset + i64(n) <= r.start + i64(r.len) {
		o := int(offset - r.start)
		return r.buf[o:][:n], .Ok
	}
	got := 0
	status := Read_Status.Ok
	for got < len(r.buf) {
		k, s := r.src.read_at(r.src.user, offset + i64(got), r.buf[got:])
		got += k
		if s != .Ok || k == 0 {
			status = s == .Ok ? .Pending : s
			break
		}
	}
	r.start = offset
	r.len = got
	if got < n do return nil, status == .Ok ? .Pending : status
	return r.buf[:n], .Ok
}

// Invalidate cached bytes (a growing source may have filled the tail).
@(private)
reader_reset :: proc(r: ^Buf_Reader) {r.start = -1; r.len = 0}

// ---------------------------------------------------------------------------
// Byte helpers

be16 :: #force_inline proc "contextless" (b: []u8) -> u16 {return u16(b[0]) << 8 | u16(b[1])}
be24 :: #force_inline proc "contextless" (b: []u8) -> u32 {return u32(b[0]) << 16 | u32(b[1]) << 8 | u32(b[2])}
be32 :: #force_inline proc "contextless" (b: []u8) -> u32 {return u32(b[0]) << 24 | u32(b[1]) << 16 | u32(b[2]) << 8 | u32(b[3])}
be64 :: #force_inline proc "contextless" (b: []u8) -> u64 {return u64(be32(b)) << 32 | u64(be32(b[4:]))}
le16 :: #force_inline proc "contextless" (b: []u8) -> u16 {return u16(b[0]) | u16(b[1]) << 8}
le32 :: #force_inline proc "contextless" (b: []u8) -> u32 {return u32(b[0]) | u32(b[1]) << 8 | u32(b[2]) << 16 | u32(b[3]) << 24}
le64 :: #force_inline proc "contextless" (b: []u8) -> u64 {return u64(le32(b)) | u64(le32(b[4:])) << 32}

@(private)
clone_bytes :: proc(b: []u8) -> []u8 {
	out := make([]u8, len(b))
	copy(out, b)
	return out
}
