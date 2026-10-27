#scope_file

// ISO BMFF / QuickTime: progressive (moov + sample tables) and fragmented
// (moof/traf/trun) files. Top-level boxes are walked as they arrive.

Trex :: struct {
	track_id: u32;
	def_dur, def_size, def_flags: u32;
}

Mp4 :: struct {
	trex: [..]Trex;
	frag_dts: Map(u32, s64); // track id -> next dts for fragments without tfdt
	elst_shift: Map(u32, s64); // track id -> media time of first edit (pts shift)
	have_moov: bool;
}
#scope_module

mp4_init :: (d: *Demuxer) {
	d.format = .MP4;
	m := new(Mp4);
	d.state = m;
	d.scan_proc = mp4_scan;
	d.free_proc = (d: *Demuxer) {
		m := cast(*Mp4)(d.state);
		delete(m.trex);
		delete(m.frag_dts);
		delete(m.elst_shift);
		free(m);
	};
}
#scope_file

Box :: struct {
	type: string; // 4 chars, points into header buffer copy
	start: s64;
	hdr: s64;
	size: s64; // total, -1 = to end of file
}

type4 :: (b: []u8) -> [4]u8 {return .[b[0], b[1], b[2], b[3]];}

mp4_scan :: (d: *Demuxer) -> Scan_Status {
	m := cast(*Mp4)(d.state);
	avail, complete := source_extent(d.src);
	if d.scan_pos >= avail {
		if complete { return ifx m.have_moov then .Done else .Error; }
		return .Need_Data;
	}
	if avail - d.scan_pos < 8 { return ifx complete then (ifx m.have_moov then .Done else .Error) else .Need_Data; }
	hb: [16]u8;
	if read_full(d.src, d.scan_pos, sub(hb, 0, 8)) != .Ok { return .Need_Data; }
	size := cast(s64)(be32(view(hb)));
	t := type4(sub_from(hb, 4));
	hdr: s64 = 8;
	if size == 1 {
		if read_full(d.src, d.scan_pos + 8, sub(hb, 8, 16)) != .Ok { return .Need_Data; }
		size = cast(s64)(be64(sub_from(hb, 8)));
		hdr = 16;
	} else if size == 0 {
		if !complete { return .Need_Data; }
		size = avail - d.scan_pos;
	}
	if size < hdr { return .Error; }
	if as_string(view(t)) == {
	case "moov"; #through; case "moof";
		if d.scan_pos + size > avail { return ifx complete then .Error else .Need_Data; }
		body := make_slice(u8, size - hdr);
		defer delete(body);
		if read_full(d.src, d.scan_pos + hdr, body) != .Ok { return .Need_Data; }
		if as_string(view(t)) == "moov" {
			parse_moov(d, m, body);
			m.have_moov = true;
			d.ready = true;
		} else {
			parse_moof(d, m, body, d.scan_pos);
		}
	}
	d.scan_pos += size;
	return .Progress;
}

// Iterate child boxes of a body buffer.
Child :: struct {
	type: string;
	body: []u8;
	off: int; // offset of body within parent buffer
}

children :: (b: []u8, out: *[..]Child) {
	clear(out);
	i := 0;
	while i + 8 <= len(b) {
		size := cast(int)(be32(sub_from(b, i)));
		hdr := 8;
		if size == 1 {
			if i + 16 > len(b) { break; }
			size = cast(int)(be64(sub_from(b, i + 8)));
			hdr = 16;
		} else if size == 0 {
			size = len(b) - i;
		}
		if size < hdr || i + size > len(b) { break; }
		append(out, Child.{as_string(sub(sub_from(b, i + 4), 0, 4)), sub(b, i + hdr, i + size), i + hdr});
		i += size;
	}
}

find :: (b: []u8, type: string) -> []u8, bool {
	cs := make_dynamic(Child, 0, 0, temp);
	children(b, *cs);
	for c: cs { if c.type == type { return c.body, true; } }
	return .{}, false;
}

find_path :: (b: []u8, path: ..string) -> []u8, bool {
	cur := b;
	for p: path {
		nb, ok := find(cur, p);
		if !ok { return .{}, false; }
		cur = nb;
	}
	return cur, true;
}

parse_moov :: (d: *Demuxer, m: *Mp4, moov: []u8) {
	cs := make_dynamic(Child, 0, 0, temp);
	children(moov, *cs);
	for c: cs {
		if c.type == {
		case "mvex";
			ms := make_dynamic(Child, 0, 0, temp);
			children(c.body, *ms);
			for x: ms {
				if x.type == "trex" && len(x.body) >= 24 {
					append(*m.trex, Trex.{be32(sub_from(x.body, 4)), be32(sub_from(x.body, 12)), be32(sub_from(x.body, 16)), be32(sub_from(x.body, 20))});
				}
			}
		}
	}
	for c: cs {
		if c.type == "trak" { parse_trak(d, m, c.body); }
	}
}

parse_trak :: (d: *Demuxer, m: *Mp4, trak: []u8) {
	t: Track;
	tkhd, ok := find(trak, "tkhd");
	if !ok || len(tkhd) < 24 { return; }
	t.id = cast(int)(ifx tkhd[0] == 1 then be32(sub_from(tkhd, 20)) else be32(sub_from(tkhd, 12)));
	mdia, ok2 := find(trak, "mdia");
	if !ok2 { return; }
	mdhd, _ := find(mdia, "mdhd");
	if len(mdhd) >= 24 {
		if mdhd[0] == 1 {
			t.timescale = cast(s64)(be32(sub_from(mdhd, 20)));
			t.duration = cast(s64)(be64(sub_from(mdhd, 24)));
		} else {
			t.timescale = cast(s64)(be32(sub_from(mdhd, 12)));
			t.duration = cast(s64)(be32(sub_from(mdhd, 16)));
		}
	}
	if t.timescale <= 0 { t.timescale = 1000; }
	hdlr, _ := find(mdia, "hdlr");
	if len(hdlr) >= 12 {
		if as_string(sub(hdlr, 8, 12)) == {
		case "vide"; t.kind = .Video;
		case "soun"; t.kind = .Audio;
		}
	}
	// Edit list: first non-empty edit's media_time shifts presentation (B-frame
	// delay, AAC priming).
	shift: s64 = 0;
	{ elst, eok := find_path(trak, "edts", "elst");
	if eok && len(elst) >= 8 {
		n := cast(int)(be32(sub_from(elst, 4)));
		v1 := elst[0] == 1;
		es := ifx v1 then 20 else 12;
		for i: 0..n-1 {
			e := sub_from(elst, 8 + i * es);
			if len(e) < es { break; }
			mt := ifx v1 then cast(s64)(be64(sub_from(e, 8))) else cast(s64)(cast(s32)(be32(sub_from(e, 4))));
			if mt >= 0 {
				shift = mt;
				break;
			}
		}
	} }
	at(*m.elst_shift, cast(u32)(t.id)).* = shift;

	stbl, sok := find_path(mdia, "minf", "stbl");
	if !sok {
		append(*d.tracks, t);
		return;
	}
	{ stsd, ok3 := find(stbl, "stsd");
	if ok3 && len(stsd) >= 16 {
		parse_stsd(*t, sub_from(stsd, 8));
	} }
	build_sample_table(*t, stbl, shift);
	if t.duration > 0 { t.duration = max(t.duration - shift, 0); }
	append(*d.tracks, t);
}

parse_stsd :: (t: *Track, entry_box: []u8) {
	// entry_box = first sample entry box (size, type, body)
	if len(entry_box) < 16 { return; }
	size := cast(int)(be32(entry_box));
	if size > len(entry_box) || size < 16 { return; }
	fmt4 := as_string(sub(entry_box, 4, 8));
	body := sub(entry_box, 8, size);
	if fmt4 == {
	case "avc1"; #through; case "avc3"; #through; case "hvc1"; #through; case "hev1"; #through; case "vp09"; #through; case "vp08"; #through; case "av01";
		if len(body) < 78 { return; }
		t.width = cast(int)(be16(sub_from(body, 24)));
		t.height = cast(int)(be16(sub_from(body, 26)));
		ext := sub_from(body, 78);
		if fmt4 == {
		case "avc1"; #through; case "avc3";
			t.codec = .H264;
			{ b, ok := find(ext, "avcC");
			if ok { t.extradata = clone_bytes(b); } }
		case "hvc1"; #through; case "hev1";
			t.codec = .HEVC;
			{ b, ok := find(ext, "hvcC");
			if ok { t.extradata = clone_bytes(b); } }
		case "vp09";
			t.codec = .VP9;
			{ b, ok := find(ext, "vpcC");
			if ok { t.extradata = clone_bytes(b); } }
		case "vp08";
			t.codec = .VP8;
		case "av01";
			t.codec = .AV1;
			{ b, ok := find(ext, "av1C");
			if ok { t.extradata = clone_bytes(b); } }
		}
	case "mp4a"; #through; case "Opus"; #through; case "fLaC"; #through; case ".mp3"; #through; case "lpcm"; #through; case "sowt"; #through; case "twos"; #through; case "ipcm"; #through; case "fpcm";
		if len(body) < 28 { return; }
		version := be16(sub_from(body, 8));
		t.channels = cast(int)(be16(sub_from(body, 16)));
		t.bits = cast(int)(be16(sub_from(body, 18)));
		t.sample_rate = cast(int)(be32(sub_from(body, 24)) >> 16);
		ext_off := 28;
		if version == 1 { ext_off += 16; }
		if version == 2 {
			ext_off += 36;
			if len(body) >= 72 {
				// v2: sample rate f64 at 32, channels at 40
				t.channels = cast(int)(be32(sub_from(body, 40)));
			}
		}
		if ext_off > len(body) { return; }
		ext := sub_from(body, ext_off);
		if fmt4 == {
		case "mp4a";
			t.codec = .AAC;
			{ esds, ok := find(ext, "esds");
			if ok && len(esds) > 4 {
				t.extradata = clone_bytes(sub_from(esds, 4));
				oti, asc := parse_es_descriptor(sub_from(esds, 4));
				if oti == 0x6B || oti == 0x69 { t.codec = .MP3; }
				if len(asc) > 0 { t.aac_asc = clone_bytes(asc); }
			} else { wave, wok := find(ext, "wave");
if wok {
				{ esds2, ok2 := find(wave, "esds");
				if ok2 && len(esds2) > 4 {
					t.extradata = clone_bytes(sub_from(esds2, 4));
					_, asc := parse_es_descriptor(sub_from(esds2, 4));
					if len(asc) > 0 { t.aac_asc = clone_bytes(asc); }
				} }
			} } }
		case ".mp3";
			t.codec = .MP3;
		case "Opus";
			t.codec = .Opus;
			{ dops, ok := find(ext, "dOps");
			if ok && len(dops) >= 11 {
				t.extradata = opus_head_from_dops(dops);
				t.pre_skip = cast(int)(be16(sub_from(dops, 2)));
				t.channels = cast(int)(dops[1]);
			} }
			t.sample_rate = 48000;
		case "fLaC";
			t.codec = .FLAC;
			{ dfla, ok := find(ext, "dfLa");
			if ok && len(dfla) > 4 {
				// FullBox; then metadata blocks (first is STREAMINFO)
				t.extradata = clone_bytes(sub_from(dfla, 4));
			} }
		case "lpcm"; #through; case "sowt"; #through; case "twos"; #through; case "ipcm"; #through; case "fpcm";
			t.codec = .PCM;
			t.pcm_big = fmt4 == "twos";
			t.pcm_float = fmt4 == "fpcm";
		}
	}
}
#scope_module

// Returns objectTypeIndication and DecoderSpecificInfo from an ES_Descriptor.
parse_es_descriptor :: (b: []u8) -> u8, []u8 {
	oti: u8;
	dsi: []u8;
	i := 0;
	read_desc :: (b: []u8, i: *int) -> u8, int, bool {
		tag: u8;
		size: int;
		ok: bool;
		if i.* >= len(b) { return tag, size, ok; }
		tag = b[i.*];
		i.* += 1;
		for _: 0..3 {
			if i.* >= len(b) { return tag, size, ok; }
			c := b[i.*];
			i.* += 1;
			size = (size << 7) | (cast(int)(c & 0x7f));
			if (c & 0x80) == 0 { break; }
		}
		ok = true;
		return tag, size, ok;
	}
	tag, size, ok := read_desc(b, *i);
	if !ok || tag != 3 { return oti, dsi; }
	end := min(i + size, len(b));
	if i + 3 > end { return oti, dsi; }
	flags := b[i + 2];
	i += 3;
	if (flags & 0x80) != 0 { i += 2; }
	if (flags & 0x40) != 0 {
		if i < end { i += 1 + cast(int)(b[i]); }
	}
	if (flags & 0x20) != 0 { i += 2; }
	while i < end {
		t2, s2, ok2 := read_desc(b, *i);
		if !ok2 { return oti, dsi; }
		if t2 == 4 {
			if i < len(b) { oti = b[i]; }
			j := i + 13;
			e2 := min(i + s2, len(b));
			while j < e2 {
				t3, s3, ok3 := read_desc(b, *j);
				if !ok3 { return oti, dsi; }
				if t3 == 5 {
					dsi = sub(b, j, min(j + s3, len(b)));
					return oti, dsi;
				}
				j += s3;
			}
			return oti, dsi;
		}
		i += s2;
	}
	return oti, dsi;
}
#scope_file

opus_head_from_dops :: (dops: []u8) -> []u8 {
	// dOps (big endian) -> OpusHead (little endian)
	h := make_dynamic(u8, 0, 0);
	append(*h, ..transmute([]u8, as_string("OpusHead")));
	append(*h, 1, dops[1]);
	ps := be16(sub_from(dops, 2));
	append(*h, cast(u8)(ps), cast(u8)(ps >> 8));
	sr := be32(sub_from(dops, 4));
	append(*h, cast(u8)(sr), cast(u8)(sr >> 8), cast(u8)(sr >> 16), cast(u8)(sr >> 24));
	g := be16(sub_from(dops, 8));
	append(*h, cast(u8)(g), cast(u8)(g >> 8));
	append(*h, dops[10]);
	if dops[10] != 0 && len(dops) > 11 { append(*h, ..sub_from(dops, 11)); }
	return view(h);
}

build_sample_table :: (t: *Track, stbl: []u8, shift: s64) {
	stts, _ := find(stbl, "stts");
	ctts, has_ctts := find(stbl, "ctts");
	stsc, _ := find(stbl, "stsc");
	stsz, _ := find(stbl, "stsz");
	stss, has_stss := find(stbl, "stss");
	stco, has_stco := find(stbl, "stco");
	co64, _ := find(stbl, "co64");
	if len(stsz) < 12 || len(stts) < 8 || len(stsc) < 8 { return; }

	count := min(cast(int)(be32(sub_from(stsz, 8))), 10_000_000);
	fixed_size := be32(sub_from(stsz, 4));
	if fixed_size == 0 { count = min(count, (len(stsz) - 12) / 4); }
	reserve(*t.packets, count);

	// sizes + dts
	stts_n := min(cast(int)(be32(sub_from(stts, 4))), (len(stts) - 8) / 8);
	e, left: int;
	dts: s64 = 0;
	ctts_n := ifx has_ctts && len(ctts) >= 8 then min(cast(int)(be32(sub_from(ctts, 4))), (len(ctts) - 8) / 8) else 0;
	ce, cleft: int;
	if stts_n > 0 { left = cast(int)(be32(sub_from(stts, 8))); }
	if ctts_n > 0 { cleft = cast(int)(be32(sub_from(ctts, 8))); }
	for i: 0..count-1 {
		p: Packet_Ref;
		p.size = cast(s32)(ifx fixed_size != 0 then fixed_size else (ifx 12 + i * 4 + 4 <= len(stsz) then be32(sub_from(stsz, 12 + i * 4)) else 0));
		while left == 0 && e + 1 < stts_n {
			e += 1;
			left = cast(int)(be32(sub_from(stts, 8 + e * 8)));
		}
		delta := cast(s64)(ifx e < stts_n then be32(sub_from(stts, 12 + e * 8)) else 0);
		left -= 1;
		cto: s64 = 0;
		if ctts_n > 0 {
			while cleft == 0 && ce + 1 < ctts_n {
				ce += 1;
				cleft = cast(int)(be32(sub_from(ctts, 8 + ce * 8)));
			}
			cto = cast(s64)(cast(s32)(be32(sub_from(ctts, 12 + ce * 8))));
			cleft -= 1;
		}
		p.dts = dts - shift;
		p.pts = dts + cto - shift;
		p.dur = cast(s32)(delta);
		p.key = !has_stss;
		dts += delta;
		append(*t.packets, p);
	}
	if has_stss && len(stss) >= 8 {
		n := cast(int)(be32(sub_from(stss, 4)));
		for i: 0..n-1 {
			if 8 + i * 4 + 4 > len(stss) { break; }
			k := cast(int)(be32(sub_from(stss, 8 + i * 4))) - 1;
			if k >= 0 && k < count { t.packets[k].key = true; }
		}
	}
	// chunk offsets
	nchunks := ifx has_stco then cast(int)(be32(sub_from(stco, 4))) else (ifx len(co64) >= 8 then cast(int)(be32(sub_from(co64, 4))) else 0);
	chunk_off :: (stco: []u8, co64: []u8, has_stco: bool, c: int) -> s64 {
		if has_stco { return cast(s64)(be32(sub_from(stco, 8 + c * 4))); }
		return cast(s64)(be64(sub_from(co64, 8 + c * 8)));
	}
	stsc_n := cast(int)(be32(sub_from(stsc, 4)));
	s := 0;
	for ent: 0..stsc_n-1 {
		first := cast(int)(be32(sub_from(stsc, 8 + ent * 12))) - 1;
		per := cast(int)(be32(sub_from(stsc, 12 + ent * 12)));
		last := ifx ent + 1 < stsc_n then cast(int)(be32(sub_from(stsc, 8 + (ent + 1) * 12))) - 1 else nchunks;
		for c: first..(min(last, nchunks))-1 {
			off := chunk_off(stco, co64, has_stco, c);
			for _: 0..per-1 {
				if s >= count { return; }
				t.packets[s].offset = off;
				off += cast(s64)(t.packets[s].size);
				s += 1;
			}
		}
	}
}

parse_moof :: (d: *Demuxer, m: *Mp4, moof: []u8, moof_start: s64) {
	cs := make_dynamic(Child, 0, 0, temp);
	children(moof, *cs);
	for c: cs {
		if c.type != "traf" { continue; }
		tcs := make_dynamic(Child, 0, 0, temp);
		children(c.body, *tcs);
		tfhd: []u8;
		for x: tcs { if x.type == "tfhd" { tfhd = x.body; } }
		if len(tfhd) < 8 { continue; }
		fl := be24(sub_from(tfhd, 1));
		tid := be32(sub_from(tfhd, 4));
		i := 8;
		base := moof_start;
		if (fl & 0x1) != 0 {base = cast(s64)(be64(sub_from(tfhd, i))); i += 8;}
		if (fl & 0x2) != 0 { i += 4; }
		trex: Trex;
		for tr: m.trex { if tr.track_id == tid { trex = tr; } }
		def_dur, def_size, def_flags := trex.def_dur, trex.def_size, trex.def_flags;
		if (fl & 0x8) != 0 {def_dur = be32(sub_from(tfhd, i)); i += 4;}
		if (fl & 0x10) != 0 {def_size = be32(sub_from(tfhd, i)); i += 4;}
		if (fl & 0x20) != 0 {def_flags = be32(sub_from(tfhd, i)); i += 4;}
		track: *Track;
		for * t: d.tracks { if cast(u32)(t.id) == tid { track = t; } }
		if track == null { continue; }
		shift := get(m.elst_shift, tid);
		dts, has_dts := map_find(m.frag_dts, tid);
		if !has_dts { dts = 0; }
		for x: tcs {
			if x.type == "tfdt" && len(x.body) >= 8 {
				dts = ifx x.body[0] == 1 then cast(s64)(be64(sub_from(x.body, 4))) else cast(s64)(be32(sub_from(x.body, 4)));
			}
		}
		data_end := base; // running data pointer for successive truns without offset
		for x: tcs {
			if x.type != "trun" || len(x.body) < 8 { continue; }
			b := x.body;
			tf := be24(sub_from(b, 1));
			n := cast(int)(be32(sub_from(b, 4)));
			j := 8;
			ptr := data_end;
			if (tf & 0x1) != 0 {ptr = base + cast(s64)(cast(s32)(be32(sub_from(b, j)))); j += 4;}
			first_flags := def_flags;
			has_first := (tf & 0x4) != 0;
			if has_first {first_flags = be32(sub_from(b, j)); j += 4;}
			for k: 0..n-1 {
				dur, size, sfl: u32 = def_dur, def_size, ifx (k == 0 && has_first) then first_flags else def_flags;
				cto: s64 = 0;
				if (tf & 0x100) != 0 {dur = be32(sub_from(b, j)); j += 4;}
				if (tf & 0x200) != 0 {size = be32(sub_from(b, j)); j += 4;}
				if (tf & 0x400) != 0 {
					f := be32(sub_from(b, j));
					j += 4;
					if !(k == 0 && has_first) { sfl = f; }
				}
				if (tf & 0x800) != 0 {
					cto = ifx b[0] == 0 then cast(s64)(be32(sub_from(b, j))) else cast(s64)(cast(s32)(be32(sub_from(b, j))));
					j += 4;
				}
				if j > len(b) { break; }
				append(*track.packets, Packet_Ref.{
					offset = ptr, size = cast(s32)(size), dts = dts - shift, pts = dts + cto - shift,
					dur = cast(s32)(dur), key = (sfl & 0x10000) == 0
				});
				ptr += cast(s64)(size);
				dts += cast(s64)(dur);
			}
			data_end = ptr;
		}
		map_set(*m.frag_dts, tid, dts);
	}
}
#scope_export

