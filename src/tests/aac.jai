// AAC decoding: one-second 440 Hz tones in tests/data/aac_*.m4a / .mp4 (ffmpeg's aac encoder: AAC-LC mono, stereo
// and 5.1, an H.264 video's soundtrack; AudioToolbox's aac_at: HE-AAC, HE-AAC v2) decode to 48 kHz stereo at the
// right pitch and length, and corrupted copies decode or fail without crashing. On Linux the decoder is build/libfc_aac.so; with
// `missing` the test checks the app without it: AAC is unsupported and nothing decodes. It also builds for
// macOS (AudioToolbox), which fails aac_he_v2.m4a for now (TODO.md).
//   jai build.jai - run src/tests/aac.jai [linux] && build/aac [missing]
#import "Basic";
#import "File";
#import "Math";
#import "String";
media :: #import "media";

FILES :: string.["aac_lc_mono.m4a", "aac_lc_stereo.m4a", "aac_lc_51.m4a", "aac_he.m4a", "aac_he_v2.m4a", "aac_video.mp4"];

main :: () {
	args := get_command_line_arguments();
	missing := args.count > 1 && args[1] == "missing";
	ok := media.audio_codec_supported(.AAC) != missing;
	if !ok print("FAIL: AAC supported is %\n", !missing);
	for FILES {
		text, rok := read_entire_file(tprint("tests/data/%", it));
		if !rok { print("FAIL: tests/data/% missing\n", it); ok = false; continue; }
		defer free(text);
		data := cast([]u8) text;
		pcm := media.decode_sound(data);
		frames := pcm.count / 2;
		seconds := cast(float64) frames / 48000;
		// pitch from the left channel's zero crossings, away from the encoder's fade-in and fade-out
		crossings := 0;
		from, to := frames / 5, frames * 4 / 5;
		for f: from + 1..to - 1 if (pcm[(f - 1) * 2] < 0) != (pcm[f * 2] < 0) crossings += 1;
		hz := ifx to > from then crossings / 2.0 / (cast(float64) (to - from) / 48000) else 0;
		good := ifx missing then frames == 0 else seconds > 0.95 && seconds < 1.25 && abs(hz - 440) < 5;
		print("%: % s, % Hz%\n", it, formatFloat(seconds, trailing_width = 3), formatFloat(hz, trailing_width = 1), ifx good then "" else "  FAIL");
		ok &= good;
		free(pcm.data);
		// corrupted frames (bytes of mdat flipped, a different stride each pass): decoded or refused, never a crash
		at := find_index_from_left(text, "mdat") - 4;
		if at < 0 continue;
		end := min(at + ((cast(int) data[at] << 24) | (cast(int) data[at + 1] << 16) | (cast(int) data[at + 2] << 8) | data[at + 3]), data.count);
		for stride: int.[7, 61, 509] {
			for i: at + 8..end - 1 if i % stride == 0 data[i] ^= 0x5A;
			free(media.decode_sound(data).data);
		}
	}
	print(ifx ok then "aac: all passed\n" else "aac: FAILED\n");
	if !ok exit(1);
}
