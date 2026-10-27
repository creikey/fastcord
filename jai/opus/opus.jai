// libopus 1.6.1 (vendor/opus), which build.sh / build.bat compile into build/fc_opus.obj. Each
// Encoder/Decoder is one allocation: a small header, then libopus's state.



Error :: enum s32 {
	None :: 0;
	Bad_Arg :: -1;
	Buffer_Too_Small :: -2;
	Internal_Error :: -3;
	Invalid_Packet :: -4;
	Unimplemented :: -5;
	Invalid_State :: -6;
	Alloc_Fail :: -7;
}

Application :: enum s32 {
	VOIP :: 2048;
	Audio :: 2049;
	Restricted_Lowdelay :: 2051;
}

Encoder :: struct {
	channels: int;
}

Decoder :: struct {
	channels: int;
}
#scope_file
	opus_encoder_get_size :: (channels: s32) -> s32 #foreign lib;
	opus_encoder_init :: (st: *void, fs: s32, channels: s32, app: Application) -> Error #foreign lib;
	opus_encode_float :: (st: *void, pcm: *float32, frame_size: s32, data: *u8, max_bytes: s32) -> s32 #foreign lib;
	opus_decoder_get_size :: (channels: s32) -> s32 #foreign lib;
	opus_decoder_init :: (st: *void, fs: s32, channels: s32) -> Error #foreign lib;
	opus_decode_float :: (st: *void, data: *u8, len: s32, pcm: *float32, frame_size: s32, decode_fec: s32) -> s32 #foreign lib;
	fc_opus_encoder_set :: (st: *void, request: s32, value: s32) -> s32 #foreign lib;

state :: inline (p: *$T) -> *void {return mem.ptr_offset(cast(*u8)(p), size_of(T));};
#scope_export

encoder_create :: (fs: int, channels: int, app: Application, allocator := context.allocator) -> *Encoder, Error {
	n := opus_encoder_get_size(cast(s32)(channels));
	if n <= 0 { return null, .Bad_Arg; }
	raw, aerr := mem.alloc(size_of(Encoder) + cast(int)(n), 8, allocator);
	if aerr != .None { return null, .Alloc_Fail; }
	e := cast(*Encoder)(raw);
	e.channels = channels;
	{ err := opus_encoder_init(state(e), cast(s32)(fs), cast(s32)(channels), app);
	if err != .None {
		mem.free(raw, allocator);
		return null, err;
	} }
	return e, .None;
}

encoder_destroy :: (e: *Encoder, allocator := context.allocator) {mem.free(e, allocator);}

encoder_set_bitrate :: (e: *Encoder, bps: int) {fc_opus_encoder_set(state(e), 4002, cast(s32)(bps));}
encoder_set_inband_fec :: (e: *Encoder, on: bool) {fc_opus_encoder_set(state(e), 4012, cast(s32) on);}
encoder_set_packet_loss_perc :: (e: *Encoder, p: int) {fc_opus_encoder_set(state(e), 4014, cast(s32)(p));}
encoder_set_dtx :: (e: *Encoder, on: bool) {fc_opus_encoder_set(state(e), 4016, cast(s32) on);}

// Encodes one frame (len(pcm)/channels samples per channel, interleaved); returns the packet length.
encode :: (e: *Encoder, pcm: []float32, out: []u8) -> int, Error {
	n := opus_encode_float(state(e), raw_data(pcm), cast(s32)(len(pcm) / e.channels), raw_data(out), cast(s32)(min(len(out), 1 << 30)));
	if n < 0 { return 0, cast(Error)(n); }
	return cast(int)(n), .None;
}

decoder_create :: (fs: int, channels: int, allocator := context.allocator) -> *Decoder, Error {
	n := opus_decoder_get_size(cast(s32)(channels));
	if n <= 0 { return null, .Bad_Arg; }
	raw, aerr := mem.alloc(size_of(Decoder) + cast(int)(n), 8, allocator);
	if aerr != .None { return null, .Alloc_Fail; }
	d := cast(*Decoder)(raw);
	d.channels = channels;
	{ err := opus_decoder_init(state(d), cast(s32)(fs), cast(s32)(channels));
	if err != .None {
		mem.free(raw, allocator);
		return null, err;
	} }
	return d, .None;
}

decoder_destroy :: (d: *Decoder, allocator := context.allocator) {mem.free(d, allocator);}

// Decodes a packet (nil = conceal a lost one) into pcm, at most len(pcm)/channels samples per channel;
// fec decodes the in-band copy of the previous packet instead. Returns samples per channel.
decode :: (d: *Decoder, packet: []u8, pcm: []float32, fec := false) -> int, Error {
	n := opus_decode_float(state(d), raw_data(packet), cast(s32)(len(packet)), raw_data(pcm), cast(s32)(len(pcm) / d.channels), cast(s32) fec);
	if n < 0 { return 0, cast(Error)(n); }
	return cast(int)(n), .None;
}

