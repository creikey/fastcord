// Decoder-state regression for latency trims; no device or network.
// jai build.jai - run src/tests/voice_jitter.jai && build/voice_jitter
#import "Basic";
#import "Math";
#import "Hash_Table";
voice :: #import "voice";

History :: struct {
    packets: int;
    ordered: bool = true;
    played: int;
}

main :: () {
    history: History;
    c: voice.Conn;
    c.opts.no_audio_devices = true;
    c.opts.callback_data = *history;
    c.opts.playback = (data: *void, uid: u64, pcm: []float32) {
        h := cast(*History) data;
        if pcm.count && pcm[0] != 0 h.played += 1;
    };
    c.codec = voice.stub_codec();
    c.codec.decode = (decoder: *void, packet: []u8, fec: bool, out: []float32) -> int {
        h := cast(*History) decoder;
        value: float32;
        if packet.count {
            h.ordered &= !fec && packet[0] == h.packets;
            h.packets += 1;
            value = cast(float32) packet[0] + 1;
        }
        for * out it.* = value;
        return 960;
    };
    user: voice.Remote_User;
    user.user_id = 1;
    user.decoder = *history;
    table_set(*c.users, 1, *user);
    defer deinit(*c.users);
    // More than target + slack; also cross the 16-bit sequence wrap.
    for i: 0..11 {
        payload := u8.[cast(u8) i];
        voice.jb_push(*user.jb, cast,no_check(u16) (65530 + i), cast(u32) (i * 960), payload, cast(float64) (i * 20));
    }
    out: [1920]float32;
    for 0..11 voice.rx_tick(*c, out);
    print("trimmed=% decoded=% played=% ordered=%\n", user.jb.stats.dropped, history.packets, history.played, history.ordered);
    if user.jb.stats.dropped == 0 || history.packets != 12 || !history.ordered exit(1);
    if history.played + cast(int) user.jb.stats.dropped != 12 exit(2);
    // A missing oldest packet must use FEC, not trim away a second packet on top of the loss.
    jb: voice.Jitter_Buffer;
    jb.playing = true;
    jb.next_seq = 100;
    for i: 101..107 {
        payload := u8.[cast(u8) i];
        voice.jb_push(*jb, cast(u16) i, cast(u32) (i * 960), payload, cast(float64) (i * 20));
    }
    trimmed: []u8;
    kind, data := voice.jb_pop(*jb, *trimmed);
    if kind != .Fec || trimmed.count != 0 || data.count != 1 || data[0] != 101 exit(3);
    if jb.stats.dropped != 0 || jb.stats.lost != 1 || jb.next_seq != 101 exit(4);

    // Empty/unprimed calls clear the discard view so a caller cannot decode it twice.
    empty: voice.Jitter_Buffer;
    trimmed = data;
    kind, data = voice.jb_pop(*empty, *trimmed);
    if kind != .None || trimmed.count != 0 exit(5);
    // Real Opus: the kept frames must decode exactly as in uninterrupted sequential decoding.
    c.codec = voice.opus_codec();
    encoder := c.codec.encoder_create(1);
    reference := c.codec.decoder_create();
    user.decoder = c.codec.decoder_create();
    if !encoder || !reference || !user.decoder exit(6);
    defer c.codec.encoder_destroy(encoder);
    defer c.codec.decoder_destroy(reference);
    defer c.codec.decoder_destroy(user.decoder);
    user.jb = .{};
    expected := NewArray(12 * 1920, float32);
    defer array_free(expected);
    mono: [960]float32;
    encoded: [voice.MAX_OPUS_PACKET]u8;
    for i: 0..11 {
        for * mono it.* = cast(float32) (0.15 * sin(TAU * 440 * (i * 960 + it_index) / 48000.0));
        size := c.codec.encode(encoder, mono, encoded);
        if size <= 0 exit(7);
        packet := array_view(encoded, 0, size);
        voice.jb_push(*user.jb, cast(u16) i, cast(u32) (i * 960), packet, cast(float64) (i * 20));
        if c.codec.decode(reference, packet, false, array_view(expected, i * 1920, 1920)) != 960 exit(8);
    }
    Real_History :: struct { user: *voice.Remote_User; expected: []float32; kept: int; }
    real: Real_History = .{*user, expected, 0};
    c.opts.callback_data = *real;
    c.opts.playback = (data: *void, uid: u64, pcm: []float32) {
        h := cast(*Real_History) data;
        index := cast(int) h.user.jb.next_seq - 1;
        if index >= 12 return; // end-of-spurt PLC, not a kept packet
        ref := array_view(h.expected, index * 1920, 1920);
        if pcm.count != ref.count || memcmp(pcm.data, ref.data, ref.count * size_of(float32)) != 0 exit(9);
        h.kept += 1;
    };
    for 0..11 voice.rx_tick(*c, out);
    if real.kept == 0 || real.kept + cast(int) user.jb.stats.dropped != 12 exit(10);
    print("PASS: decoder history, bounded trims, sequence wrap, FEC, empty buffer, real Opus reference\n");
}
