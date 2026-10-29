// Fuzzing: jai build.jai - fuzz <target> [seconds]. Replays every file in tests/fuzz/<target>/ (seeds and
// the crashes found so far, kept as regression tests), then feeds mutations of them to the parser until the
// time is up. Bounds checks are on, so a bad index stops the run; each input is written to
// build/fuzz_inputs/<target>.last first, and build.jai saves it under tests/fuzz/<target>/ when the run dies.
// A run past 2 s on one input counts as a hang.
#import "Basic";
#import "File";
#import "File_Utilities";
#import "Random";
#import "String";
etf :: #import "etf";
lottie :: #import "lottie";
media :: #import "media";
#if OS == .WINDOWS msvcprt :: #library,system,no_dll,link_always "msvcprt";

TARGETS :: string.["etf", "json", "lottie", "demux"];

run :: (target: string, data: []u8) {
	if target == {
	case "etf";
		etf.decode(data,, temp);
	case "json";
		v, err := etf.from_json(cast(string) data,, temp);
		if err == .None { sb: String_Builder; sb.allocator = temp; etf.to_json(v, *sb); }
	case "lottie";
		anim := lottie.load(data);
		if !anim return;
		p: lottie.Player;
		lottie.player_init(*p, 32, 32);
		lottie.render(*p, anim, 0);
		lottie.render(*p, anim, lottie.frame_at(anim, 0.5));
		lottie.player_destroy(*p);
		lottie.destroy(anim);
	case "demux";
		src := media.source_from_memory(data);
		d := media.demux_open(*src);
		if !d return;
		media.demux_scan_all(d);
		buf: [..]u8;
		for * t: d.tracks for t.packets media.demux_read(d, it, *buf);
		array_free(buf);
		media.demux_destroy(d);
	}
}

// Built-in seeds, for a target whose directory is still empty.
SEED :: string.[
	"\x83t\0\0\0\x02m\0\0\0\x02opa\x01m\0\0\0\x01dl\0\0\0\x01a\x05jj",
	"{\"op\":1,\"d\":[1,2.5,\"x\",null,true,{\"a\":[[]]}]}",
	"{\"w\":64,\"h\":64,\"fr\":30,\"ip\":0,\"op\":30,\"layers\":[{\"ty\":4,\"ks\":{},\"shapes\":[{\"ty\":\"gr\",\"it\":[{\"ty\":\"rc\",\"p\":{\"k\":[32,32]},\"s\":{\"k\":[20,20]}},{\"ty\":\"fl\",\"c\":{\"k\":[1,0,0,1]},\"o\":{\"k\":100}}]}]}]}",
	"\0\0\0\x10ftypisom\0\0\0\0\0\0\0\x08moov",
];

mutate :: (seeds: [][]u8) -> []u8 {
	src := seeds[random_get() % cast(u64) seeds.count];
	out: [..]u8;
	out.allocator = temp;
	array_add(*out, ..src);
	INTERESTING :: u8.[0, 1, 0x7F, 0x80, 0xFF, #char "[", #char "{", #char "\"", #char "-", #char "9"];
	for 0..cast(int) (random_get() % 4) {
		if !out.count { array_add(*out, xx random_get()); continue; }
		at := cast(int) (random_get() % cast(u64) out.count);
		if random_get() % 6 == {
		case 0; out[at] ^= cast(u8) (1 << (random_get() % 8));
		case 1; out[at] = INTERESTING[random_get() % INTERESTING.count];
		case 2; out[at] = xx random_get();
		case 3; // delete a run
			n := min(cast(int) (random_get() % 16) + 1, out.count - at);
			for at..out.count - n - 1 out[it] = out[it + n];
			out.count -= n;
		case 4; // repeat a run
			n := min(cast(int) (random_get() % 16) + 1, out.count - at);
			piece := array_copy(array_view(out, at, n),, temp);
			for 1..cast(int) (random_get() % 8) + 1 array_add(*out, ..piece);
		case 5; // splice in part of another seed
			other := seeds[random_get() % cast(u64) seeds.count];
			if !other.count continue;
			from := cast(int) (random_get() % cast(u64) other.count);
			array_add(*out, ..array_view(other, from, min(64, other.count - from)));
		}
	}
	return out;
}

main :: () {
	args := get_command_line_arguments();
	target := ifx args.count > 1 then args[1] else "";
	known, ti := array_find(TARGETS, target);
	if !known { print("fuzz targets: %\n", TARGETS); exit(2); }
	seconds := ifx args.count > 2 then string_to_int(args[2]) else 30;
	make_directory_if_it_does_not_exist("build/fuzz_inputs", recursive = true);
	last := sprint("build/fuzz_inputs/%.last", target); // not temp: each run resets it
	seeds: [..][]u8;
	for file_list(tprint("tests/fuzz/%", target)) {
		data, ok := read_entire_file(it);
		if !ok continue;
		write_entire_file(last, data);
		run(target, cast([]u8) data); // a crash found earlier, or a seed
		array_add(*seeds, cast([]u8) data);
	}
	replayed := seeds.count;
	// test fixtures make better seeds than the built-in ones
	FIXTURES :: string.["", "tests/data/collectibles_categories.json", "", "tests/ui/media/clip.mp4"];
	if FIXTURES[ti] {
		data, ok := read_entire_file(FIXTURES[ti]);
		if ok array_add(*seeds, cast([]u8) data);
	}
	if !seeds array_add(*seeds, cast([]u8) SEED[ti]);
	random_seed(cast(u64) to_milliseconds(current_time_consensus()));
	start := seconds_since_init();
	runs := 0;
	while seconds_since_init() - start < xx seconds {
		reset_temporary_storage();
		input := mutate(seeds);
		write_entire_file(last, input.data, input.count);
		t := seconds_since_init();
		run(target, input);
		if seconds_since_init() - t > 2 { print("fuzz %: an input took % s (a hang), saved as %\n", target, seconds_since_init() - t, last); exit(3); }
		runs += 1;
		if runs % 64 == 0 && seeds.count < 256 array_add(*seeds, array_copy(input)); // keep exploring from mutants
	}
	print("fuzz %: % files replayed, % runs, no crash\n", target, replayed, runs);
}
