#scope_file

// MP3 (frame sync), WAV (RIFF), native FLAC (frame sync + header CRC-8).

// ---------------------------------------------------------------------------
// MP3

Mp3 :: struct {
	started: bool;
	pts: s64;
	first: bool;
}
#scope_module

mp3_init :: (d: *Demuxer) {
	d.format = .MP3;
	d.state = new(Mp3);
	d.scan_proc = mp3_scan;
	d.free_proc = (d: *Demuxer) {free(d.state);};
}
#scope_export

Mp3_Header :: struct {
	size: int;
	sample_rate: int;
	channels: int;
	samples: int;
	ok: bool;
}

mp3_parse_header :: (h: []u8) -> Mp3_Header {
	r: Mp3_Header;
	if len(h) < 4 || h[0] != 0xFF || h[1] & 0xE0 != 0xE0 { return r; }
	ver := (h[1] >> 3) & 3; // 3 = MPEG1, 2 = MPEG2, 0 = MPEG2.5
	layer := (h[1] >> 1) & 3; // 1 = Layer III
	if ver == 1 || layer == 0 { return r; }
	br_idx := cast(int)(h[2] >> 4);
	sr_idx := cast(int)((h[2] >> 2) & 3);
	if br_idx == 0 || br_idx == 15 || sr_idx == 3 { return r; }
	pad := cast(int)((h[2] >> 1) & 1);
	BR_V1_L3 := int.[0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0];
	BR_V1_L2 := int.[0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 0];
	BR_V1_L1 := int.[0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448, 0];
	BR_V2_L1 := int.[0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256, 0];
	BR_V2_L23 := int.[0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0];
	SR := int.[44100, 48000, 32000];
	sr := SR[sr_idx];
	if ver == 2 { sr /= 2; }
	if ver == 0 { sr /= 4; }
	br: int;
	if ver == 3 {
		if layer == {
		case 3; br = BR_V1_L1[br_idx];
		case 2; br = BR_V1_L2[br_idx];
		case 1; br = BR_V1_L3[br_idx];
		}
	} else {
		br = ifx layer == 3 then BR_V2_L1[br_idx] else BR_V2_L23[br_idx];
	}
	br *= 1000;
	if layer == {
	case 3; // Layer I
		r.samples = 384;
		r.size = (12 * br / sr + pad) * 4;
	case 2;
		r.samples = 1152;
		r.size = 144 * br / sr + pad;
	case 1;
		r.samples = ifx ver == 3 then 1152 else 576;
		r.size = (ifx ver == 3 then 144 else 72) * br / sr + pad;
	}
	r.sample_rate = sr;
	r.channels = ifx (h[3] >> 6) == 3 then 1 else 2;
	r.ok = r.size > 4;
	return r;
}
#scope_file

mp3_scan :: (d: *Demuxer) -> Scan_Status {
	m := cast(*Mp3)(d.state);
	avail, complete := source_extent(d.src);
	if !m.started {
		h, s := peek(*d.reader, 0, 10);
		if s != .Ok { return ifx complete then .Error else .Need_Data; }
		if as_string(sub(h, 0, 3)) == "ID3" {
			sz := cast(s64)(h[6]) << 21 | cast(s64)(h[7]) << 14 | cast(s64)(h[8]) << 7 | cast(s64)(h[9]);
			d.scan_pos = 10 + sz + (ifx (h[5] & 0x10) != 0 then 10 else 0);
		}
		m.started = true;
		m.first = true;
	}
	if d.scan_pos + 4 > avail {
		if complete { return ifx len(d.tracks) > 0 then .Done else .Error; }
		reader_reset(*d.reader);
		return .Need_Data;
	}
	h, s := peek(*d.reader, d.scan_pos, 4);
	if s != .Ok {
		if complete { return .Done; }
		reader_reset(*d.reader);
		return .Need_Data;
	}
	fh := mp3_parse_header(h);
	if !fh.ok {
		if len(d.tracks) > 0 && as_string(sub(h, 0, 3)) == "TAG" { return .Done; } // ID3v1 trailer
		d.scan_pos += 1; // resync
		return .Progress;
	}
	if d.scan_pos + cast(s64)(fh.size) > avail && !complete { return .Need_Data; }
	if len(d.tracks) == 0 {
		append(*d.tracks, Track.{id = 1, kind = .Audio, codec = .MP3, sample_rate = fh.sample_rate, channels = fh.channels, timescale = cast(s64)(fh.sample_rate)});
		d.ready = true;
	}
	t := *d.tracks[0];
	skip := false;
	if m.first {
		m.first = false;
		// Xing/Info/VBRI header frame carries no audio
		{ body, bs := peek(*d.reader, d.scan_pos, min(fh.size, 200));
		if bs == .Ok {
			for k: 4..(len(body) - 4)-1 {
				tag := as_string(sub(sub_from(body, k), 0, 4));
				if tag == "Xing" || tag == "Info" || tag == "VBRI" {
					skip = true;
					break;
				}
			}
		} }
	}
	if !skip {
		append(*t.packets, Packet_Ref.{offset = d.scan_pos, size = cast(s32)(fh.size), pts = m.pts, dts = m.pts, dur = cast(s32)(fh.samples), key = true});
		m.pts += cast(s64)(fh.samples);
		t.duration = m.pts;
	}
	d.scan_pos += cast(s64)(fh.size);
	return .Progress;
}
#scope_module

// ---------------------------------------------------------------------------
// WAV

wav_init :: (d: *Demuxer) {
	d.format = .WAV;
	d.scan_proc = wav_scan;
	d.scan_pos = 12;
}
#scope_file

wav_scan :: (d: *Demuxer) -> Scan_Status {
	avail, complete := source_extent(d.src);
	h, s := peek(*d.reader, d.scan_pos, 8);
	if s != .Ok {
		if complete { return ifx len(d.tracks) > 0 then .Done else .Error; }
		reader_reset(*d.reader);
		return .Need_Data;
	}
	id := as_string(sub(h, 0, 4));
	size := cast(s64)(le32(sub_from(h, 4)));
	body := d.scan_pos + 8;
	if id == {
	case "fmt ";
		f, fs := peek(*d.reader, body, cast(int)(min(size, 40)));
		if fs != .Ok { return .Need_Data; }
		tag := le16(f);
		t := Track.{id = 1, kind = .Audio, codec = .PCM};
		t.channels = cast(int)(le16(sub_from(f, 2)));
		t.sample_rate = cast(int)(le32(sub_from(f, 4)));
		t.bits = cast(int)(le16(sub_from(f, 14)));
		if t.sample_rate < 8000 || t.sample_rate > 384000 { return .Error; }
		t.timescale = cast(s64)(t.sample_rate);
		if tag == 0xFFFE && len(f) >= 26 { tag = le16(sub_from(f, 24)); }
		t.pcm_float = tag == 3;
		if tag != 1 && tag != 3 { t.codec = .Unknown; }
		append(*d.tracks, t);
	case "data";
		if len(d.tracks) == 0 { return .Error; }
		t := *d.tracks[0];
		d.ready = true;
		frame_bytes := cast(s64)(t.channels * t.bits / 8);
		if frame_bytes <= 0 { return .Error; }
		if size == 0 || size == 0xFFFFFFFF || body + size > avail && complete { size = avail - body; }
		CHUNK :: 4096;
		total_frames := size / frame_bytes;
		have_frames := min(total_frames, (avail - body) / frame_bytes);
		done_frames := cast(s64)(len(t.packets)) * CHUNK;
		while done_frames < have_frames {
			n := min(cast(s64)(CHUNK), total_frames - done_frames);
			if done_frames + n > have_frames && !complete { break; }
			append(*t.packets, Packet_Ref.{offset = body + done_frames * frame_bytes, size = cast(s32)(n * frame_bytes), pts = done_frames, dts = done_frames, dur = cast(s32)(n), key = true});
			done_frames += n;
		}
		t.duration = total_frames;
		if done_frames < total_frames { return ifx complete then .Done else .Need_Data; }
		return .Done;
	}
	d.scan_pos = body + size + (size & 1);
	return .Progress;
}

// ---------------------------------------------------------------------------
// FLAC (native). Frames are found by sync code + header CRC-8.

Flac :: struct {
	in_frames: bool;
	block_size: int; // fixed block size from STREAMINFO (min == max), else 0
	pts: s64;
	frame_at: s64; // start of current frame (-1 = none yet)
	frame_samples: int;
}
#scope_module

flac_init :: (d: *Demuxer) {
	d.format = .FLAC;
	f := new(Flac);
	f.frame_at = -1;
	d.state = f;
	d.scan_proc = flac_scan;
	d.free_proc = (d: *Demuxer) {free(d.state);};
	d.scan_pos = 4;
}
#scope_file

crc8 :: (b: []u8) -> u8 {
	c: u8 = 0;
	for x: b {
		c ^= x;
		for _: 0..7 { c = ifx (c & 0x80) != 0 then (c << 1) ^ 0x07 else c << 1; }
	}
	return c;
}

// Validates a frame header at h; returns block size in samples or 0.
flac_frame_header :: (h: []u8, si_rate: int) -> int {
	if len(h) < 16 || h[0] != 0xFF || (h[1] & 0xFE) != 0xF8 { return 0; }
	bs_code := cast(int)(h[2] >> 4);
	sr_code := cast(int)(h[2] & 0xF);
	if bs_code == 0 || sr_code == 15 { return 0; }
	if (h[3] >> 4) >= 11 || (h[3] >> 1) & 7 == 3 || (h[3] >> 1) & 7 == 7 { return 0; }
	i := 4;
	// UTF-8-style coded number
	c := h[i];
	extra := 0;
	if c & 0x80 == 0 { extra = 0;
	} else if c & 0xE0 == 0xC0 { extra = 1;
	} else if c & 0xF0 == 0xE0 { extra = 2;
	} else if c & 0xF8 == 0xF0 { extra = 3;
	} else if c & 0xFC == 0xF8 { extra = 4;
	} else if c & 0xFE == 0xFC { extra = 5;
	} else if c == 0xFE { extra = 6;
	} else { return 0;
	}
	i += 1 + extra;
	bs := 0;
	if bs_code == 1 { bs = 192;
	} else if (bs_code >= 2 && bs_code <= 5) { bs = 576 << cast(u64)(bs_code - 2);
	} else if bs_code == 6 { bs = cast(int)(h[i]) + 1; i += 1;
	} else if bs_code == 7 { bs = cast(int)(be16(sub_from(h, i))) + 1; i += 2;
	} else if (bs_code >= 8 && bs_code <= 15) { bs = 256 << cast(u64)(bs_code - 8);
	}
	if sr_code == {
	case 12; i += 1;
	case 13; #through; case 14; i += 2;
	}
	if i >= len(h) { return 0; }
	if crc8(sub(h, 0, i)) != h[i] { return 0; }
	return bs;
}

flac_scan :: (d: *Demuxer) -> Scan_Status {
	f := cast(*Flac)(d.state);
	avail, complete := source_extent(d.src);
	if !f.in_frames {
		h, s := peek(*d.reader, d.scan_pos, 4);
		if s != .Ok { return ifx complete then .Error else .Need_Data; }
		last := h[0] & 0x80 != 0;
		btype := h[0] & 0x7F;
		size := cast(s64)(be24(sub_from(h, 1)));
		if btype == 0 {
			b, bs := peek(*d.reader, d.scan_pos, 4 + 34);
			if bs != .Ok { return .Need_Data; }
			t := Track.{id = 1, kind = .Audio, codec = .FLAC};
			si := sub_from(b, 4);
			minb, maxb := cast(int)(be16(si)), cast(int)(be16(sub_from(si, 2)));
			if minb == maxb { f.block_size = minb; }
			t.sample_rate = cast(int)(be24(sub_from(si, 10)) >> 4);
			t.channels = cast(int)((si[12] >> 1) & 7) + 1;
			t.bits = cast(int)(((si[12] & 1) << 4) | (si[13] >> 4)) + 1;
			t.timescale = cast(s64)(t.sample_rate);
			t.duration = cast(s64)(si[13] & 0xF) << 32 | cast(s64)(be32(sub_from(si, 14)));
			t.extradata = clone_bytes(sub(b, 0, 38)); // metadata block header + STREAMINFO
			t.extradata[0] |= 0x80; // mark as last block
			append(*d.tracks, t);
		}
		d.scan_pos += 4 + size;
		if last {
			f.in_frames = true;
			d.ready = len(d.tracks) > 0;
		}
		return .Progress;
	}
	t := *d.tracks[0];
	// Search for the next frame header after scan_pos (the current frame's start is frame_at).
	CHUNK :: 32 * 1024;
	n := cast(int)(min(avail - d.scan_pos, CHUNK));
	if n < 16 {
		if complete {
			if f.frame_at >= 0 {
				append(*t.packets, Packet_Ref.{offset = f.frame_at, size = cast(s32)(avail - f.frame_at), pts = f.pts, dts = f.pts, dur = cast(s32)(f.frame_samples), key = true});
				f.frame_at = -1;
			}
			return .Done;
		}
		reader_reset(*d.reader);
		return .Need_Data;
	}
	b, s := peek(*d.reader, d.scan_pos, n);
	if s != .Ok { return .Need_Data; }
	for i: 0..(n - 16)-1 {
		if b[i] != 0xFF || (b[i + 1] & 0xFE) != 0xF8 { continue; }
		bs := flac_frame_header(sub_from(b, i), t.sample_rate);
		if bs == 0 { continue; }
		at := d.scan_pos + cast(s64)(i);
		if f.frame_at >= 0 && at > f.frame_at {
			append(*t.packets, Packet_Ref.{offset = f.frame_at, size = cast(s32)(at - f.frame_at), pts = f.pts, dts = f.pts, dur = cast(s32)(f.frame_samples), key = true});
			f.pts += cast(s64)(f.frame_samples);
		}
		f.frame_at = at;
		f.frame_samples = bs;
		d.scan_pos = at + 2;
		return .Progress;
	}
	if d.scan_pos + cast(s64)(n) >= avail {
		// searched to the end of available data
		if complete {
			if f.frame_at >= 0 {
				append(*t.packets, Packet_Ref.{offset = f.frame_at, size = cast(s32)(avail - f.frame_at), pts = f.pts, dts = f.pts, dur = cast(s32)(f.frame_samples), key = true});
				f.frame_at = -1;
			}
			return .Done;
		}
		reader_reset(*d.reader);
		return .Need_Data;
	}
	d.scan_pos += cast(s64)(n - 16);
	return .Progress;
}
#scope_export

