// A streamed MP4 whose index (moov) comes after its media: once the head shows the mdat first, the
// growing buffer asks for the tail from the moov's offset, and with only the head's first bytes and that
// tail the demuxer is ready (tracks and duration), so the player can start.
//   jai build.jai - run src/tests/stream_tail.jai && build/stream_tail
#import "Basic";
#import "File";
media :: #import "media";

main :: () {
    ok := true;
    data, rok := read_entire_file("tests/data/moov_last.mp4"); // ffmpeg's default: ftyp, free, mdat, moov
    ok &= check(rok, "fixture");
    file := cast([]u8) data;
    g := media.growing_create();
    media.growing_append(g, array_view(file, 0, 16));
    ok &= check(media.growing_tail_wanted(g) == -1, "nothing asked before the mdat's header is in");
    media.growing_append(g, array_view(file, 16, 1024 - 16));
    off := media.growing_tail_wanted(g);
    ok &= check(off > 0 && off + 8 <= file.count && cast(string) array_view(file, off + 4, 4) == "moov", "the tail is asked from the moov (% of %)", off, file.count);
    ok &= check(media.growing_tail_wanted(g) == -1, "asked once");
    if off > 0 {
        media.growing_append_tail(g, array_view(file, off, file.count - off));
        media.growing_finish_tail(g, true);
    }
    src := media.source_from_growing(g);
    d, st := media.demux_open(*src);
    ok &= check(d != null, "demux_open on the head (%)", st);
    if d {
        for 1..10 if !d.ready media.demux_scan_headers(d);
        ok &= check(d.ready && media.demux_duration(d) > 2.5, "ready with a duration of % s before the media is in", media.demux_duration(d));
    }
    print(ifx ok then "PASS\n" else "FAIL\n");
    if !ok exit(1);
}

check :: (cond: bool, what: string, args: ..Any) -> bool {
    if !cond print("FAIL: %\n", tprint(what, ..args));
    return cond;
}
