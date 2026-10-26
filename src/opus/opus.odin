package opus

// libopus 1.6.1 (vendor/opus), which build.sh / build.bat compile into build/fc_opus.obj. Each
// Encoder/Decoder is one allocation: a small header, then libopus's state.

import "core:mem"

when ODIN_OS == .Windows {
	foreign import lib "../../build/fc_opus.obj"
} else {
	foreign import lib "../../build/fc_opus.o"
}

Error :: enum i32 {
	None             = 0,
	Bad_Arg          = -1,
	Buffer_Too_Small = -2,
	Internal_Error   = -3,
	Invalid_Packet   = -4,
	Unimplemented    = -5,
	Invalid_State    = -6,
	Alloc_Fail       = -7,
}

Application :: enum i32 {
	VOIP                = 2048,
	Audio               = 2049,
	Restricted_Lowdelay = 2051,
}

Encoder :: struct #align (16) {
	channels: int,
}

Decoder :: struct #align (16) {
	channels: int,
}

@(default_calling_convention = "c")
@(private = "file")
foreign lib {
	opus_encoder_get_size :: proc(channels: i32) -> i32 ---
	opus_encoder_init :: proc(st: rawptr, fs, channels: i32, app: Application) -> Error ---
	opus_encode_float :: proc(st: rawptr, pcm: [^]f32, frame_size: i32, data: [^]u8, max_bytes: i32) -> i32 ---
	opus_decoder_get_size :: proc(channels: i32) -> i32 ---
	opus_decoder_init :: proc(st: rawptr, fs, channels: i32) -> Error ---
	opus_decode_float :: proc(st: rawptr, data: [^]u8, len: i32, pcm: [^]f32, frame_size: i32, decode_fec: b32) -> i32 ---
	fc_opus_encoder_set :: proc(st: rawptr, request: i32, value: i32) -> i32 ---
}

@(private = "file")
state :: #force_inline proc(p: ^$T) -> rawptr {return mem.ptr_offset((^u8)(p), size_of(T))}

encoder_create :: proc(fs: int, channels: int, app: Application, allocator := context.allocator) -> (^Encoder, Error) {
	n := opus_encoder_get_size(i32(channels))
	if n <= 0 do return nil, .Bad_Arg
	raw, aerr := mem.alloc(size_of(Encoder) + int(n), align_of(Encoder), allocator)
	if aerr != nil do return nil, .Alloc_Fail
	e := (^Encoder)(raw)
	e.channels = channels
	if err := opus_encoder_init(state(e), i32(fs), i32(channels), app); err != .None {
		free(raw, allocator)
		return nil, err
	}
	return e, .None
}

encoder_destroy :: proc(e: ^Encoder, allocator := context.allocator) {free(e, allocator)}

encoder_set_bitrate :: proc(e: ^Encoder, bps: int) {fc_opus_encoder_set(state(e), 4002, i32(bps))}
encoder_set_inband_fec :: proc(e: ^Encoder, on: bool) {fc_opus_encoder_set(state(e), 4012, on ? 1 : 0)}
encoder_set_packet_loss_perc :: proc(e: ^Encoder, p: int) {fc_opus_encoder_set(state(e), 4014, i32(p))}
encoder_set_dtx :: proc(e: ^Encoder, on: bool) {fc_opus_encoder_set(state(e), 4016, on ? 1 : 0)}

// Encodes one frame (len(pcm)/channels samples per channel, interleaved); returns the packet length.
encode :: proc(e: ^Encoder, pcm: []f32, out: []u8) -> (int, Error) {
	n := opus_encode_float(state(e), raw_data(pcm), i32(len(pcm) / e.channels), raw_data(out), i32(min(len(out), 1 << 30)))
	if n < 0 do return 0, Error(n)
	return int(n), .None
}

decoder_create :: proc(fs: int, channels: int, allocator := context.allocator) -> (^Decoder, Error) {
	n := opus_decoder_get_size(i32(channels))
	if n <= 0 do return nil, .Bad_Arg
	raw, aerr := mem.alloc(size_of(Decoder) + int(n), align_of(Decoder), allocator)
	if aerr != nil do return nil, .Alloc_Fail
	d := (^Decoder)(raw)
	d.channels = channels
	if err := opus_decoder_init(state(d), i32(fs), i32(channels)); err != .None {
		free(raw, allocator)
		return nil, err
	}
	return d, .None
}

decoder_destroy :: proc(d: ^Decoder, allocator := context.allocator) {free(d, allocator)}

// Decodes a packet (nil = conceal a lost one) into pcm, at most len(pcm)/channels samples per channel;
// fec decodes the in-band copy of the previous packet instead. Returns samples per channel.
decode :: proc(d: ^Decoder, packet: []u8, pcm: []f32, fec := false) -> (int, Error) {
	n := opus_decode_float(state(d), raw_data(packet), i32(len(packet)), raw_data(pcm), i32(len(pcm) / d.channels), b32(fec))
	if n < 0 do return 0, Error(n)
	return int(n), .None
}
