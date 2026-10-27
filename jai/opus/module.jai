// libopus (vendor/opus). Each Encoder/Decoder is one allocation in context.allocator: a small header,
// then libopus's state.
#import "Basic";

Error :: enum s32 {
    None             :: 0;
    Bad_Arg          :: -1;
    Buffer_Too_Small :: -2;
    Internal_Error   :: -3;
    Invalid_Packet   :: -4;
    Unimplemented    :: -5;
    Invalid_State    :: -6;
    Alloc_Fail       :: -7;
}

Application :: enum s32 { VOIP :: 2048; Audio :: 2049; Restricted_Lowdelay :: 2051; }

Encoder :: struct { channels: int; }
Decoder :: struct { channels: int; }

encoder_create :: (fs: int, channels: int, app: Application) -> *Encoder, Error {
    n := opus_encoder_get_size(xx channels);
    if n <= 0 return null, .Bad_Arg;
    e := cast(*Encoder) alloc(size_of(Encoder) + n);
    e.channels = channels;
    err := opus_encoder_init(state(e), xx fs, xx channels, app);
    if err != .None { free(e); return null, err; }
    return e, .None;
}
encoder_destroy :: (e: *Encoder) { free(e); }

encoder_set_bitrate          :: (e: *Encoder, bps: int) { fc_opus_encoder_set(state(e), 4002, xx bps); }
encoder_set_inband_fec       :: (e: *Encoder, on: bool) { fc_opus_encoder_set(state(e), 4012, xx on); }
encoder_set_packet_loss_perc :: (e: *Encoder, p: int)   { fc_opus_encoder_set(state(e), 4014, xx p); }
encoder_set_dtx              :: (e: *Encoder, on: bool) { fc_opus_encoder_set(state(e), 4016, xx on); }

// encode encodes one frame (pcm.count/channels samples per channel, interleaved); returns the packet length.
encode :: (e: *Encoder, pcm: []float32, out: []u8) -> int, Error {
    n := opus_encode_float(state(e), pcm.data, xx (pcm.count / e.channels), out.data, xx min(out.count, 1 << 30));
    if n < 0 return 0, cast(Error) n;
    return n, .None;
}

decoder_create :: (fs: int, channels: int) -> *Decoder, Error {
    n := opus_decoder_get_size(xx channels);
    if n <= 0 return null, .Bad_Arg;
    d := cast(*Decoder) alloc(size_of(Decoder) + n);
    d.channels = channels;
    err := opus_decoder_init(state(d), xx fs, xx channels);
    if err != .None { free(d); return null, err; }
    return d, .None;
}
decoder_destroy :: (d: *Decoder) { free(d); }

// decode decodes a packet (empty = conceal a lost one) into pcm, at most pcm.count/channels samples per
// channel; fec decodes the in-band copy of the previous packet instead. Returns samples per channel.
decode :: (d: *Decoder, packet: []u8, pcm: []float32, fec := false) -> int, Error {
    n := opus_decode_float(state(d), packet.data, xx packet.count, pcm.data, xx (pcm.count / d.channels), xx fec);
    if n < 0 return 0, cast(Error) n;
    return n, .None;
}

#scope_file
state :: inline (p: *$T) -> *void { return cast(*u8) p + size_of(T); }
lib :: #library,no_dll "../../build/fc_vendor";
opus_encoder_get_size :: (channels: s32) -> s32 #foreign lib;
opus_encoder_init :: (st: *void, fs: s32, channels: s32, app: Application) -> Error #foreign lib;
opus_encode_float :: (st: *void, pcm: *float32, frame_size: s32, data: *u8, max_bytes: s32) -> s32 #foreign lib;
opus_decoder_get_size :: (channels: s32) -> s32 #foreign lib;
opus_decoder_init :: (st: *void, fs: s32, channels: s32) -> Error #foreign lib;
opus_decode_float :: (st: *void, data: *u8, len: s32, pcm: *float32, frame_size: s32, decode_fec: s32) -> s32 #foreign lib;
fc_opus_encoder_set :: (st: *void, request: s32, value: s32) -> s32 #foreign lib;
