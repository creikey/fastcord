// ISO BMFF / QuickTime: progressive (moov + sample tables) and fragmented
// (moof/traf/trun) files. Top-level boxes are walked as they arrive.

#scope_module

mp4_init :: (d: *Demuxer) {
	d.format = .MP4;
	d.state = New(Mp4);
	d.scan_proc = mp4_scan;
	d.free_proc = (d: *Demuxer) {
		m := cast(*Mp4) d.state;
		array_free(m.trex);
		deinit(*m.frag_dts);
		deinit(*m.elst_shift);
		free(m);
	};
}

// Returns objectTypeIndication and DecoderSpecificInfo from an ES_Descriptor.
parse_es_descriptor :: (b: []u8) -> u8, []u8 {
	read_desc :: (b: []u8, i: *int) -> u8, int, bool {
		if i.* >= b.count return 0, 0, false;
		tag := b[i.*];
		i.* += 1;
		size := 0;
		for 0..3 {
			if i.* >= b.count return tag, size, false;
			c := b[i.*];
			i.* += 1;
			size = (size << 7) | (c & 0x7f);
			if (c & 0x80) == 0 break;
		}
		return tag, size, true;
	}
	i := 0;
	tag, size, ok := read_desc(b, *i);
	if !ok || tag != 3 return 0, .[];
	end := min(i + size, b.count);
	if i + 3 > end return 0, .[];
	flags := b[i + 2];
	i += 3;
	if flags & 0x80 i += 2;
	if (flags & 0x40) != 0 && i < end i += 1 + b[i];
	if flags & 0x20 i += 2;
	while i < end {
		t2, s2, ok2 := read_desc(b, *i);
		if !ok2 return 0, .[];
		if t2 == 4 {
			oti: u8 = ifx i < b.count then b[i] else 0;
			j := i + 13;
			e2 := min(i + s2, b.count);
			while j < e2 {
				t3, s3, ok3 := read_desc(b, *j);
				if !ok3 return oti, .[];
				if t3 == 5 return oti, array_view(b, j, min(j + s3, b.count) - j);
				j += s3;
			}
			return oti, .[];
		}
		i += s2;
	}
	return 0, .[];
}

#scope_file

MAX_PACKETS :: 10_000_000; // per track

Trex :: struct {
	track_id: u32;
	def_dur, def_size, def_flags: u32;
}

Mp4 :: struct {
	trex: [..]Trex;
	frag_dts: Table(u32, s64); // track id -> next dts for fragments without tfdt
	elst_shift: Table(u32, s64); // track id -> media time of first edit (pts shift)
	have_moov: bool;
}

mp4_scan :: (d: *Demuxer) -> Scan_Status {
	m := cast(*Mp4) d.state;
	avail, complete := source_extent(d.src);
	if d.scan_pos >= avail {
		if complete return ifx m.have_moov then .Done else .Error;
		return .Need_Data;
	}
	if avail - d.scan_pos < 8 return ifx complete then (ifx m.have_moov then Scan_Status.Done else .Error) else .Need_Data;
	hb: [16]u8;
	if read_full(d.src, d.scan_pos, array_view(hb, 0, 8)) != .Ok return .Need_Data;
	size := cast(s64) be32(hb);
	hdr: s64 = 8;
	if size == 1 {
		if read_full(d.src, d.scan_pos + 8, array_view(hb, 8, 8)) != .Ok return .Need_Data;
		size = cast(s64) be64(hb, 8);
		hdr = 16;
	} else if size == 0 {
		if !complete return .Need_Data;
		size = avail - d.scan_pos;
	}
	if size < hdr || size > S64_MAX - d.scan_pos return .Error; // a 64-bit size can be negative or wrap
	type := str(hb, 4, 4);
	if type == "moov" || type == "moof" {
		if d.scan_pos + size > avail return ifx complete then .Error else .Need_Data;
		body := NewArray(size - hdr, u8, initialized = false);
		defer array_free(body);
		if read_full(d.src, d.scan_pos + hdr, body) != .Ok return .Need_Data;
		if type == "moov" {
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

// Child boxes of a body buffer (temp).
Child :: struct {
	type: string;
	body: []u8;
}

children :: (b: []u8) -> [..]Child {
	out: [..]Child;
	out.allocator = temp;
	i := 0;
	while i + 8 <= b.count {
		size := cast(int) be32(b, i);
		hdr := 8;
		if size == 1 {
			if i + 16 > b.count break;
			size = cast(int) be64(b, i + 8);
			hdr = 16;
		} else if size == 0 {
			size = b.count - i;
		}
		if size < hdr || size > b.count - i break;
		array_add(*out, .{str(b, i + 4, 4), array_view(b, i + hdr, size - hdr)});
		i += size;
	}
	return out;
}

find :: (b: []u8, path: ..string) -> []u8, bool {
	cur := b;
	for p: path {
		found := false;
		for children(cur) if it.type == p { cur = it.body; found = true; break; }
		if !found return .[], false;
	}
	return cur, true;
}

parse_moov :: (d: *Demuxer, m: *Mp4, moov: []u8) {
	cs := children(moov);
	for c: cs if c.type == "mvex" {
		for x: children(c.body) if x.type == "trex" && x.body.count >= 24 {
			array_add(*m.trex, .{be32(x.body, 4), be32(x.body, 12), be32(x.body, 16), be32(x.body, 20)});
		}
	}
	for cs if it.type == "trak" parse_trak(d, m, it.body);
}

parse_trak :: (d: *Demuxer, m: *Mp4, trak: []u8) {
	t: Track;
	tkhd, ok := find(trak, "tkhd");
	if !ok || tkhd.count < 24 return;
	t.id = ifx tkhd[0] == 1 then be32(tkhd, 20) else be32(tkhd, 12);
	mdia, ok2 := find(trak, "mdia");
	if !ok2 return;
	mdhd := find(mdia, "mdhd");
	if mdhd.count >= 20 {
		if mdhd[0] == 1 {
			t.timescale = be32(mdhd, 20);
			t.duration = cast(s64) be64(mdhd, 24);
		} else {
			t.timescale = be32(mdhd, 12);
			t.duration = be32(mdhd, 16);
		}
	}
	if t.timescale <= 0 t.timescale = 1000;
	hdlr := find(mdia, "hdlr");
	if hdlr.count >= 12 {
		h := str(hdlr, 8, 4);
		if h == "vide" t.kind = .Video;
		else if h == "soun" t.kind = .Audio;
	}
	// Edit list: first non-empty edit's media_time shifts presentation (B-frame
	// delay, AAC priming).
	shift: s64 = 0;
	elst, eok := find(trak, "edts", "elst");
	if eok && elst.count >= 8 {
		v1 := elst[0] == 1;
		es := ifx v1 then 20 else 12;
		for i: 0..cast(int) be32(elst, 4) - 1 {
			e := array_view(elst, 8 + i * es);
			if e.count < es break;
			mt := ifx v1 then cast(s64) be64(e, 8) else cast(s64) cast(s32) be32(e, 4);
			if mt >= 0 {
				shift = mt;
				break;
			}
		}
	}
	table_set(*m.elst_shift, cast(u32) t.id, shift);

	stbl, sok := find(mdia, "minf", "stbl");
	if sok {
		stsd, ok3 := find(stbl, "stsd");
		if ok3 && stsd.count >= 16 parse_stsd(*t, array_view(stsd, 8));
		build_sample_table(*t, stbl, shift);
		if t.duration > 0 t.duration = max(t.duration - shift, 0);
	}
	array_add(*d.tracks, t);
}

parse_stsd :: (t: *Track, entry_box: []u8) {
	// entry_box = first sample entry box (size, type, body)
	if entry_box.count < 16 return;
	size := cast(int) be32(entry_box);
	if size > entry_box.count || size < 16 return;
	fmt4 := str(entry_box, 4, 4);
	body := array_view(entry_box, 8, size - 8);
	if fmt4 == {
	case "avc1"; #through;
	case "avc3"; #through;
	case "hvc1"; #through;
	case "hev1"; #through;
	case "vp09"; #through;
	case "vp08"; #through;
	case "av01";
		if body.count < 78 return;
		t.width = be16(body, 24);
		t.height = be16(body, 26);
		ext := array_view(body, 78);
		atom: string;
		if fmt4 == {
		case "avc1"; #through;
		case "avc3"; t.codec = .H264; atom = "avcC";
		case "hvc1"; #through;
		case "hev1"; t.codec = .HEVC; atom = "hvcC";
		case "vp09"; t.codec = .VP9; atom = "vpcC";
		case "vp08"; t.codec = .VP8;
		case "av01"; t.codec = .AV1; atom = "av1C";
		}
		if atom {
			b, ok := find(ext, atom);
			if ok t.extradata = array_copy(b);
		}
	case "mp4a"; #through;
	case "Opus"; #through;
	case "fLaC"; #through;
	case ".mp3"; #through;
	case "lpcm"; #through;
	case "sowt"; #through;
	case "twos"; #through;
	case "ipcm"; #through;
	case "fpcm";
		if body.count < 28 return;
		version := be16(body, 8);
		t.channels = be16(body, 16);
		t.bits = be16(body, 18);
		t.sample_rate = be32(body, 24) >> 16;
		ext_off := 28;
		if version == 1 ext_off += 16;
		if version == 2 {
			ext_off += 36;
			// v2: sample rate f64 at 32, channels at 40
			if body.count >= 72 t.channels = be32(body, 40);
		}
		if ext_off > body.count return;
		ext := array_view(body, ext_off);
		if fmt4 == {
		case "mp4a";
			t.codec = .AAC;
			esds, ok := find(ext, "esds");
			if ok && esds.count > 4 {
				t.extradata = array_copy(array_view(esds, 4));
				oti, asc := parse_es_descriptor(array_view(esds, 4));
				if oti == 0x6B || oti == 0x69 t.codec = .MP3;
				if asc.count t.aac_asc = array_copy(asc);
			} else {
				esds2, ok2 := find(ext, "wave", "esds");
				if ok2 && esds2.count > 4 {
					t.extradata = array_copy(array_view(esds2, 4));
					_, asc := parse_es_descriptor(array_view(esds2, 4));
					if asc.count t.aac_asc = array_copy(asc);
				}
			}
		case ".mp3";
			t.codec = .MP3;
		case "Opus";
			t.codec = .Opus;
			dops, ok := find(ext, "dOps");
			if ok && dops.count >= 11 {
				t.extradata = opus_head_from_dops(dops);
				t.pre_skip = be16(dops, 2);
				t.channels = dops[1];
			}
			t.sample_rate = 48000;
		case "fLaC";
			t.codec = .FLAC;
			// FullBox; then metadata blocks (first is STREAMINFO)
			dfla, ok := find(ext, "dfLa");
			if ok && dfla.count > 4 t.extradata = array_copy(array_view(dfla, 4));
		case;
			t.codec = .PCM;
			t.pcm_big = fmt4 == "twos";
			t.pcm_float = fmt4 == "fpcm";
		}
	}
}

// dOps (big endian) -> OpusHead (little endian)
opus_head_from_dops :: (dops: []u8) -> []u8 {
	h: [..]u8;
	array_add(*h, ..cast([]u8) "OpusHead");
	ps := be16(dops, 2);
	sr := be32(dops, 4);
	g := be16(dops, 8);
	array_add(*h, 1, dops[1], cast,trunc(u8) ps, cast,trunc(u8) (ps >> 8),
		cast,trunc(u8) sr, cast,trunc(u8) (sr >> 8), cast,trunc(u8) (sr >> 16), cast,trunc(u8) (sr >> 24),
		cast,trunc(u8) g, cast,trunc(u8) (g >> 8), dops[10]);
	if dops[10] != 0 && dops.count > 11 array_add(*h, ..array_view(dops, 11));
	return h;
}

build_sample_table :: (t: *Track, stbl: []u8, shift: s64) {
	stts := find(stbl, "stts");
	ctts, has_ctts := find(stbl, "ctts");
	stsc := find(stbl, "stsc");
	stsz := find(stbl, "stsz");
	stss, has_stss := find(stbl, "stss");
	stco, has_stco := find(stbl, "stco");
	co64 := find(stbl, "co64");
	if stsz.count < 12 || stts.count < 8 || stsc.count < 8 return;

	count := min(cast(int) be32(stsz, 8), MAX_PACKETS);
	fixed_size := be32(stsz, 4);
	if fixed_size == 0 count = min(count, (stsz.count - 12) / 4);
	array_reserve(*t.packets, count);

	// sizes + dts
	stts_n := min(cast(int) be32(stts, 4), (stts.count - 8) / 8);
	e, left: int;
	dts: s64 = 0;
	ctts_n := ifx has_ctts && ctts.count >= 8 then min(cast(int) be32(ctts, 4), (ctts.count - 8) / 8) else 0;
	ce, cleft: int;
	if stts_n > 0 left = be32(stts, 8);
	if ctts_n > 0 cleft = be32(ctts, 8);
	for i: 0..count - 1 {
		p: Packet_Ref;
		p.size = cast(s32) ifx fixed_size != 0 then fixed_size else ifx 12 + i * 4 + 4 <= stsz.count then be32(stsz, 12 + i * 4) else 0;
		while left == 0 && e + 1 < stts_n {
			e += 1;
			left = be32(stts, 8 + e * 8);
		}
		delta: s64 = ifx e < stts_n then be32(stts, 12 + e * 8) else 0;
		left -= 1;
		cto: s64 = 0;
		if ctts_n > 0 {
			while cleft == 0 && ce + 1 < ctts_n {
				ce += 1;
				cleft = be32(ctts, 8 + ce * 8);
			}
			cto = cast(s32) be32(ctts, 12 + ce * 8);
			cleft -= 1;
		}
		p.dts = dts - shift;
		p.pts = dts + cto - shift;
		p.dur = cast(s32) delta;
		p.key = !has_stss;
		dts += delta;
		array_add(*t.packets, p);
	}
	if has_stss && stss.count >= 8 {
		for i: 0..cast(int) be32(stss, 4) - 1 {
			if 8 + i * 4 + 4 > stss.count break;
			k := cast(int) be32(stss, 8 + i * 4) - 1;
			if k >= 0 && k < count t.packets[k].key = true;
		}
	}
	// chunk offsets
	nchunks := ifx has_stco then cast(int) be32(stco, 4) else ifx co64.count >= 8 then cast(int) be32(co64, 4) else 0;
	nchunks = min(nchunks, ifx has_stco then (stco.count - 8) / 4 else (co64.count - 8) / 8);
	stsc_n := min(cast(int) be32(stsc, 4), (stsc.count - 8) / 12);
	s := 0;
	for ent: 0..stsc_n - 1 {
		first := max(cast(int) be32(stsc, 8 + ent * 12) - 1, 0);
		per := cast(int) be32(stsc, 12 + ent * 12);
		last := ifx ent + 1 < stsc_n then cast(int) be32(stsc, 8 + (ent + 1) * 12) - 1 else nchunks;
		for c: first..min(last, nchunks) - 1 {
			off := ifx has_stco then cast(s64) be32(stco, 8 + c * 4) else cast(s64) be64(co64, 8 + c * 8);
			for 0..per - 1 {
				if s >= count return;
				t.packets[s].offset = off;
				off += t.packets[s].size;
				s += 1;
			}
		}
	}
}

parse_moof :: (d: *Demuxer, m: *Mp4, moof: []u8, moof_start: s64) {
	for c: children(moof) {
		if c.type != "traf" continue;
		tcs := children(c.body);
		tfhd: []u8;
		for tcs if it.type == "tfhd" tfhd = it.body;
		if tfhd.count < 8 continue;
		fl := be24(tfhd, 1);
		tid := be32(tfhd, 4);
		i := 8;
		base := moof_start;
		if fl & 0x1 { base = cast(s64) be64(tfhd, i); i += 8; }
		if fl & 0x2 i += 4;
		trex: Trex;
		for m.trex if it.track_id == tid trex = it;
		def_dur, def_size, def_flags := trex.def_dur, trex.def_size, trex.def_flags;
		if fl & 0x8 { def_dur = be32(tfhd, i); i += 4; }
		if fl & 0x10 { def_size = be32(tfhd, i); i += 4; }
		if fl & 0x20 { def_flags = be32(tfhd, i); i += 4; }
		track: *Track;
		for * d.tracks if cast(u32) it.id == tid track = it;
		if !track continue;
		_, shift := table_find(*m.elst_shift, tid);
		_, dts := table_find(*m.frag_dts, tid);
		for tcs if it.type == "tfdt" && it.body.count >= (ifx it.body[0] == 1 then 12 else 8) {
			dts = ifx it.body[0] == 1 then cast(s64) be64(it.body, 4) else cast(s64) be32(it.body, 4);
		}
		data_end := base; // running data pointer for successive truns without offset
		for x: tcs {
			if x.type != "trun" || x.body.count < 8 continue;
			b := x.body;
			tf := be24(b, 1);
			n := min(cast(int) be32(b, 4), MAX_PACKETS - track.packets.count); // samples need not take bytes here
			j := 8;
			ptr := data_end;
			if tf & 0x1 { ptr = base + cast(s32) be32(b, j); j += 4; }
			first_flags := def_flags;
			has_first := (tf & 0x4) != 0;
			if has_first { first_flags = be32(b, j); j += 4; }
			for k: 0..n - 1 {
				first := k == 0 && has_first;
				dur, size, sfl := def_dur, def_size, ifx first then first_flags else def_flags;
				cto: s64 = 0;
				if tf & 0x100 { dur = be32(b, j); j += 4; }
				if tf & 0x200 { size = be32(b, j); j += 4; }
				if tf & 0x400 {
					f := be32(b, j);
					j += 4;
					if !first sfl = f;
				}
				if tf & 0x800 {
					cto = ifx b[0] == 0 then cast(s64) be32(b, j) else cast(s64) cast(s32) be32(b, j);
					j += 4;
				}
				if j > b.count break;
				array_add(*track.packets, .{
					offset = ptr, size = cast(s32) size, dts = dts - shift, pts = dts + cto - shift,
					dur = cast(s32) dur, key = (sfl & 0x10000) == 0
				});
				ptr += size;
				dts += dur;
			}
			data_end = ptr;
		}
		table_set(*m.frag_dts, tid, dts);
	}
}
