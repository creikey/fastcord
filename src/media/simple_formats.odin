package media

// MP3 (frame sync), WAV (RIFF), native FLAC (frame sync + header CRC-8).

// ---------------------------------------------------------------------------
// MP3

@(private = "file")
Mp3 :: struct {
	started: bool,
	pts:     i64,
	first:   bool,
}

@(private)
mp3_init :: proc(d: ^Demuxer) {
	d.format = .MP3
	d.state = new(Mp3)
	d.scan_proc = mp3_scan
	d.free_proc = proc(d: ^Demuxer) {free(d.state)}
}

Mp3_Header :: struct {
	size:        int,
	sample_rate: int,
	channels:    int,
	samples:     int,
	ok:          bool,
}

mp3_parse_header :: proc(h: []u8) -> (r: Mp3_Header) {
	if len(h) < 4 || h[0] != 0xFF || h[1] & 0xE0 != 0xE0 do return
	ver := (h[1] >> 3) & 3 // 3 = MPEG1, 2 = MPEG2, 0 = MPEG2.5
	layer := (h[1] >> 1) & 3 // 1 = Layer III
	if ver == 1 || layer == 0 do return
	br_idx := int(h[2] >> 4)
	sr_idx := int((h[2] >> 2) & 3)
	if br_idx == 0 || br_idx == 15 || sr_idx == 3 do return
	pad := int((h[2] >> 1) & 1)
	BR_V1_L3 := [16]int{0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0}
	BR_V1_L2 := [16]int{0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 0}
	BR_V1_L1 := [16]int{0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448, 0}
	BR_V2_L1 := [16]int{0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256, 0}
	BR_V2_L23 := [16]int{0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0}
	SR := [3]int{44100, 48000, 32000}
	sr := SR[sr_idx]
	if ver == 2 do sr /= 2
	if ver == 0 do sr /= 4
	br: int
	if ver == 3 {
		switch layer {
		case 3: br = BR_V1_L1[br_idx]
		case 2: br = BR_V1_L2[br_idx]
		case 1: br = BR_V1_L3[br_idx]
		}
	} else {
		br = layer == 3 ? BR_V2_L1[br_idx] : BR_V2_L23[br_idx]
	}
	br *= 1000
	switch layer {
	case 3: // Layer I
		r.samples = 384
		r.size = (12 * br / sr + pad) * 4
	case 2:
		r.samples = 1152
		r.size = 144 * br / sr + pad
	case 1:
		r.samples = ver == 3 ? 1152 : 576
		r.size = (ver == 3 ? 144 : 72) * br / sr + pad
	}
	r.sample_rate = sr
	r.channels = (h[3] >> 6) == 3 ? 1 : 2
	r.ok = r.size > 4
	return
}

@(private = "file")
mp3_scan :: proc(d: ^Demuxer) -> Scan_Status {
	m := (^Mp3)(d.state)
	avail, complete := source_extent(d.src)
	if !m.started {
		h, s := peek(&d.reader, 0, 10)
		if s != .Ok do return complete ? .Error : .Need_Data
		if string(h[:3]) == "ID3" {
			sz := i64(h[6]) << 21 | i64(h[7]) << 14 | i64(h[8]) << 7 | i64(h[9])
			d.scan_pos = 10 + sz + ((h[5] & 0x10) != 0 ? 10 : 0)
		}
		m.started = true
		m.first = true
	}
	if d.scan_pos + 4 > avail {
		if complete do return len(d.tracks) > 0 ? .Done : .Error
		reader_reset(&d.reader)
		return .Need_Data
	}
	h, s := peek(&d.reader, d.scan_pos, 4)
	if s != .Ok {
		if complete do return .Done
		reader_reset(&d.reader)
		return .Need_Data
	}
	fh := mp3_parse_header(h)
	if !fh.ok {
		if len(d.tracks) > 0 && string(h[:3]) == "TAG" do return .Done // ID3v1 trailer
		d.scan_pos += 1 // resync
		return .Progress
	}
	if d.scan_pos + i64(fh.size) > avail && !complete do return .Need_Data
	if len(d.tracks) == 0 {
		append(&d.tracks, Track{id = 1, kind = .Audio, codec = .MP3, sample_rate = fh.sample_rate, channels = fh.channels, timescale = i64(fh.sample_rate)})
		d.ready = true
	}
	t := &d.tracks[0]
	skip := false
	if m.first {
		m.first = false
		// Xing/Info/VBRI header frame carries no audio
		if body, bs := peek(&d.reader, d.scan_pos, min(fh.size, 200)); bs == .Ok {
			for k in 4 ..< len(body) - 4 {
				tag := string(body[k:][:4])
				if tag == "Xing" || tag == "Info" || tag == "VBRI" {
					skip = true
					break
				}
			}
		}
	}
	if !skip {
		append(&t.packets, Packet_Ref{offset = d.scan_pos, size = i32(fh.size), pts = m.pts, dts = m.pts, dur = i32(fh.samples), key = true})
		m.pts += i64(fh.samples)
		t.duration = m.pts
	}
	d.scan_pos += i64(fh.size)
	return .Progress
}

// ---------------------------------------------------------------------------
// WAV

@(private)
wav_init :: proc(d: ^Demuxer) {
	d.format = .WAV
	d.scan_proc = wav_scan
	d.scan_pos = 12
}

@(private = "file")
wav_scan :: proc(d: ^Demuxer) -> Scan_Status {
	avail, complete := source_extent(d.src)
	h, s := peek(&d.reader, d.scan_pos, 8)
	if s != .Ok {
		if complete do return len(d.tracks) > 0 ? .Done : .Error
		reader_reset(&d.reader)
		return .Need_Data
	}
	id := string(h[:4])
	size := i64(le32(h[4:]))
	body := d.scan_pos + 8
	switch id {
	case "fmt ":
		f, fs := peek(&d.reader, body, int(min(size, 40)))
		if fs != .Ok do return .Need_Data
		tag := le16(f)
		t := Track{id = 1, kind = .Audio, codec = .PCM}
		t.channels = int(le16(f[2:]))
		t.sample_rate = int(le32(f[4:]))
		t.bits = int(le16(f[14:]))
		if t.sample_rate < 8000 || t.sample_rate > 384000 do return .Error
		t.timescale = i64(t.sample_rate)
		if tag == 0xFFFE && len(f) >= 26 do tag = le16(f[24:])
		t.pcm_float = tag == 3
		if tag != 1 && tag != 3 do t.codec = .Unknown
		append(&d.tracks, t)
	case "data":
		if len(d.tracks) == 0 do return .Error
		t := &d.tracks[0]
		d.ready = true
		frame_bytes := i64(t.channels * t.bits / 8)
		if frame_bytes <= 0 do return .Error
		if size == 0 || size == 0xFFFFFFFF || body + size > avail && complete do size = avail - body
		CHUNK :: 4096
		total_frames := size / frame_bytes
		have_frames := min(total_frames, (avail - body) / frame_bytes)
		done_frames := i64(len(t.packets)) * CHUNK
		for done_frames < have_frames {
			n := min(i64(CHUNK), total_frames - done_frames)
			if done_frames + n > have_frames && !complete do break
			append(&t.packets, Packet_Ref{offset = body + done_frames * frame_bytes, size = i32(n * frame_bytes), pts = done_frames, dts = done_frames, dur = i32(n), key = true})
			done_frames += n
		}
		t.duration = total_frames
		if done_frames < total_frames do return complete ? .Done : .Need_Data
		return .Done
	}
	d.scan_pos = body + size + (size & 1)
	return .Progress
}

// ---------------------------------------------------------------------------
// FLAC (native). Frames are found by sync code + header CRC-8.

@(private = "file")
Flac :: struct {
	in_frames:  bool,
	block_size: int, // fixed block size from STREAMINFO (min == max), else 0
	pts:        i64,
	frame_at:   i64, // start of current frame (-1 = none yet)
	frame_samples: int,
}

@(private)
flac_init :: proc(d: ^Demuxer) {
	d.format = .FLAC
	f := new(Flac)
	f.frame_at = -1
	d.state = f
	d.scan_proc = flac_scan
	d.free_proc = proc(d: ^Demuxer) {free(d.state)}
	d.scan_pos = 4
}

@(private = "file")
crc8 :: proc(b: []u8) -> u8 {
	c: u8 = 0
	for x in b {
		c ~= x
		for _ in 0 ..< 8 do c = (c & 0x80) != 0 ? (c << 1) ~ 0x07 : c << 1
	}
	return c
}

// Validates a frame header at h; returns block size in samples or 0.
@(private = "file")
flac_frame_header :: proc(h: []u8, si_rate: int) -> int {
	if len(h) < 16 || h[0] != 0xFF || (h[1] & 0xFE) != 0xF8 do return 0
	bs_code := int(h[2] >> 4)
	sr_code := int(h[2] & 0xF)
	if bs_code == 0 || sr_code == 15 do return 0
	if (h[3] >> 4) >= 11 || (h[3] >> 1) & 7 == 3 || (h[3] >> 1) & 7 == 7 do return 0
	i := 4
	// UTF-8-style coded number
	c := h[i]
	extra := 0
	switch {
	case c & 0x80 == 0: extra = 0
	case c & 0xE0 == 0xC0: extra = 1
	case c & 0xF0 == 0xE0: extra = 2
	case c & 0xF8 == 0xF0: extra = 3
	case c & 0xFC == 0xF8: extra = 4
	case c & 0xFE == 0xFC: extra = 5
	case c == 0xFE: extra = 6
	case: return 0
	}
	i += 1 + extra
	bs := 0
	switch bs_code {
	case 1: bs = 192
	case 2 ..= 5: bs = 576 << uint(bs_code - 2)
	case 6: bs = int(h[i]) + 1; i += 1
	case 7: bs = int(be16(h[i:])) + 1; i += 2
	case 8 ..= 15: bs = 256 << uint(bs_code - 8)
	}
	switch sr_code {
	case 12: i += 1
	case 13, 14: i += 2
	}
	if i >= len(h) do return 0
	if crc8(h[:i]) != h[i] do return 0
	return bs
}

@(private = "file")
flac_scan :: proc(d: ^Demuxer) -> Scan_Status {
	f := (^Flac)(d.state)
	avail, complete := source_extent(d.src)
	if !f.in_frames {
		h, s := peek(&d.reader, d.scan_pos, 4)
		if s != .Ok do return complete ? .Error : .Need_Data
		last := h[0] & 0x80 != 0
		btype := h[0] & 0x7F
		size := i64(be24(h[1:]))
		if btype == 0 {
			b, bs := peek(&d.reader, d.scan_pos, 4 + 34)
			if bs != .Ok do return .Need_Data
			t := Track{id = 1, kind = .Audio, codec = .FLAC}
			si := b[4:]
			minb, maxb := int(be16(si)), int(be16(si[2:]))
			if minb == maxb do f.block_size = minb
			t.sample_rate = int(be24(si[10:]) >> 4)
			t.channels = int((si[12] >> 1) & 7) + 1
			t.bits = int(((si[12] & 1) << 4) | (si[13] >> 4)) + 1
			t.timescale = i64(t.sample_rate)
			t.duration = i64(si[13] & 0xF) << 32 | i64(be32(si[14:]))
			t.extradata = clone_bytes(b[:38]) // metadata block header + STREAMINFO
			t.extradata[0] |= 0x80 // mark as last block
			append(&d.tracks, t)
		}
		d.scan_pos += 4 + size
		if last {
			f.in_frames = true
			d.ready = len(d.tracks) > 0
		}
		return .Progress
	}
	t := &d.tracks[0]
	// Search for the next frame header after scan_pos (the current frame's start is frame_at).
	CHUNK :: 32 * 1024
	n := int(min(avail - d.scan_pos, CHUNK))
	if n < 16 {
		if complete {
			if f.frame_at >= 0 {
				append(&t.packets, Packet_Ref{offset = f.frame_at, size = i32(avail - f.frame_at), pts = f.pts, dts = f.pts, dur = i32(f.frame_samples), key = true})
				f.frame_at = -1
			}
			return .Done
		}
		reader_reset(&d.reader)
		return .Need_Data
	}
	b, s := peek(&d.reader, d.scan_pos, n)
	if s != .Ok do return .Need_Data
	for i in 0 ..< n - 16 {
		if b[i] != 0xFF || (b[i + 1] & 0xFE) != 0xF8 do continue
		bs := flac_frame_header(b[i:], t.sample_rate)
		if bs == 0 do continue
		at := d.scan_pos + i64(i)
		if f.frame_at >= 0 && at > f.frame_at {
			append(&t.packets, Packet_Ref{offset = f.frame_at, size = i32(at - f.frame_at), pts = f.pts, dts = f.pts, dur = i32(f.frame_samples), key = true})
			f.pts += i64(f.frame_samples)
		}
		f.frame_at = at
		f.frame_samples = bs
		d.scan_pos = at + 2
		return .Progress
	}
	if d.scan_pos + i64(n) >= avail {
		// searched to the end of available data
		if complete {
			if f.frame_at >= 0 {
				append(&t.packets, Packet_Ref{offset = f.frame_at, size = i32(avail - f.frame_at), pts = f.pts, dts = f.pts, dur = i32(f.frame_samples), key = true})
				f.frame_at = -1
			}
			return .Done
		}
		reader_reset(&d.reader)
		return .Need_Data
	}
	d.scan_pos += i64(n - 16)
	return .Progress
}
