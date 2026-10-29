// Demuxer check: jai build.jai - run src/tests/demux.jai, then build/demux. Crafted files (any user's
// attachment) must be refused or indexed without reading out of bounds, aborting or running away.
#import "Basic";
media :: #import "media";

failed := 0;

check :: (ok: bool, what: string) {
	if !ok { print("FAIL: %\n", what); failed += 1; }
}

// run demuxes data to the end and reads every packet; it returns the packets indexed and the seconds taken.
run :: (data: []u8) -> packets: int, seconds: float64 {
	t0 := seconds_since_init();
	src := media.source_from_memory(data);
	d, s := media.demux_open(*src);
	if !d return 0, seconds_since_init() - t0;
	defer media.demux_destroy(d);
	media.demux_scan_all(d);
	n := 0;
	buf: [..]u8;
	defer array_free(buf);
	for * t: d.tracks for t.packets {
		media.demux_read(d, it, *buf);
		n += 1;
	}
	return n, seconds_since_init() - t0;
}

u32be :: (v: u64) -> [4]u8 { return .[xx,trunc (v >> 24), xx,trunc (v >> 16), xx,trunc (v >> 8), xx,trunc v]; }

// box: an MP4 box of the given type around body.
box :: (type: string, body: ..[]u8) -> []u8 {
	out: [..]u8;
	n := 8;
	for body n += it.count;
	array_add(*out, ..u32be(xx n));
	array_add(*out, ..cast([]u8) type);
	for body array_add(*out, ..it);
	return out;
}

bytes :: (v: ..u64) -> []u8 {
	out: [..]u8;
	for v array_add(*out, ..u32be(it));
	return out;
}

main :: () {
	ftyp := box("ftyp", cast([]u8) "isom", bytes(0));
	tkhd := box("tkhd", bytes(0, 0, 0, 1, 0, 0));
	hdlr := box("hdlr", bytes(0, 0), cast([]u8) "vide", bytes(0, 0, 0));
	mdhd_short := box("mdhd", cast([]u8) "\x01\0\0\0", bytes(0, 0, 0, 0, 1000)); // version 1, 20 bytes: needs 32
	stts := box("stts", bytes(0, 1, 3, 1));
	stsz := box("stsz", bytes(0, 0, 3, 100, 0xFFFF_FFFF, 0x8000_0000)); // a negative and a huge sample
	stsc := box("stsc", bytes(0, 0xFFFF_FFFF, 1, 0xFFFF_FFFF, 1)); // count far past the box
	stco := box("stco", bytes(0, 0xFFFF_FFFF, 0));
	stbl := box("stbl", stts, stsz, stsc, stco);
	trak := box("trak", tkhd, box("mdia", mdhd_short, hdlr, box("minf", stbl)));
	n, secs := run(concat(ftyp, box("moov", trak)));
	check(secs < 2, tprint("MP4 with bad counts and sizes (% packets, % s)", n, secs));

	// a moof whose trun claims 4 billion samples with no per-sample fields, and a short tfdt v1
	mvex := box("mvex", box("trex", bytes(0, 1, 1, 1, 10, 0)));
	moov := box("moov", mvex, box("trak", tkhd, box("mdia", box("mdhd", bytes(0, 0, 0, 1000, 0)), hdlr, box("minf", box("stbl", stts, box("stsz", bytes(0, 0, 0)), box("stsc", bytes(0, 0)), box("stco", bytes(0, 0)))))));
	traf := box("traf", box("tfhd", bytes(0x3B, 1)), box("tfdt", cast([]u8) "\x01\0\0\0", bytes(0)), box("trun", bytes(0, 0xFFFF_FFFF)));
	n, secs = run(concat(ftyp, moov, box("moof", traf)));
	check(secs < 10, tprint("trun with 4 billion samples (% packets, % s)", n, secs));

	// a box with a 64-bit size near S64_MAX
	huge := concat(bytes(1), cast([]u8) "moov", bytes(0x7FFF_FFFF, 0xFFFF_FFF0));
	n, secs = run(concat(ftyp, huge));
	check(secs < 2, "64-bit box size near S64_MAX");

	// Matroska: a Cluster Timecode of 100 KB, and a BlockGroup child of unknown size
	ebml := cast([]u8) "\x1A\x45\xDF\xA3\x80";
	segment := cast([]u8) "\x18\x53\x80\x67\x01\xFF\xFF\xFF\xFF\xFF\xFF\xFF";
	track := cast([]u8) "\xAE\x86\xD7\x81\x01\x83\x81\x02";
	tracks := concat(cast([]u8) "\x16\x54\xAE\x6B\x88", track);
	cluster := cast([]u8) "\x1F\x43\xB6\x75\x01\xFF\xFF\xFF\xFF\xFF\xFF\xFF";
	timecode := concat(cast([]u8) "\xE7\x42\x00\x01\x86\xA0", NewArray(100_000, u8));
	group := cast([]u8) "\xA0\x88\x9B\xFF\xA1\x84\x81\0\0\x80";
	n, secs = run(concat(ebml, segment, tracks, cluster, group, timecode));
	check(secs < 2, tprint("Matroska with an oversized timecode (% packets)", n));

	// FLAC with no STREAMINFO: its only metadata block is the last and a PADDING block
	n, secs = run(concat(cast([]u8) "fLaC", cast([]u8) "\x81\0\0\0", cast([]u8) "\xFF\xF8\x69\x08\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0"));
	check(n == 0, "FLAC without STREAMINFO is refused");

	if failed { print("demux: % failed\n", failed); exit(1); }
	print("demux: ok\n");
}

concat :: (parts: ..[]u8) -> []u8 {
	out: [..]u8;
	for parts array_add(*out, ..it);
	return out;
}
