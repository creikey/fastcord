#+build windows
package media

// Windows decoders: TODO Media Foundation (H.264/HEVC/VP9/AV1 MFTs -> NV12
// ID3D11Texture2D, AAC/MP3/Opus/FLAC audio MFTs). Until then this backend
// reports every codec unsupported, so players on Windows open, probe and
// demux but render no frames and play no audio. PCM (WAV) is decoded here.

import "fc:gfx"
import "fc:audio"

Video_Frame :: struct {
	pts:    f64,
	dur:    f64,
	pixbuf: rawptr,
	width:  int,
	height: int,
	yuv:    gfx.Yuv_Matrix,
}

Video_Decoder :: struct {
	errors: int,
}

video_codec_supported :: proc(c: Codec) -> bool {return false}
video_decoder_create :: proc(t: ^Track, first_packet: []u8 = nil) -> (^Video_Decoder, bool) {return nil, false}
video_decode :: proc(vd: ^Video_Decoder, data: []u8, pts, dts, dur: f64) -> bool {return false}
video_decoder_flush :: proc(vd: ^Video_Decoder) {}
video_decoder_take :: proc(vd: ^Video_Decoder, out: ^[dynamic]Video_Frame) {}
video_decoder_destroy :: proc(vd: ^Video_Decoder) {}
video_frame_release :: proc(f: ^Video_Frame) {f.pixbuf = nil}
video_frame_textures :: proc(f: ^Video_Frame) -> (y, cbcr: gfx.Texture, ok: bool) {return}

Audio_Decoder :: struct {
	channels:  int,
	rate:      int,
	bits:      int,
	is_float:  bool,
	big:       bool,
	pos:       f64, // resampler phase
	tmp:       [dynamic]f32,
}

audio_codec_supported :: proc(c: Codec) -> bool {return c == .PCM}

audio_decoder_create :: proc(t: ^Track) -> (^Audio_Decoder, bool) {
	if t.codec != .PCM do return nil, false
	ad := new(Audio_Decoder)
	ad^ = {channels = max(t.channels, 1), rate = max(t.sample_rate, 1), bits = max(t.bits, 8), is_float = t.pcm_float, big = t.pcm_big}
	return ad, true
}

// PCM -> f32, linear-interpolation resample to 48 kHz, -> stereo.
audio_decode :: proc(ad: ^Audio_Decoder, data: []u8, out: ^[dynamic]f32) -> bool {
	bps := ad.bits / 8
	frames := len(data) / (bps * ad.channels)
	clear(&ad.tmp)
	for f in 0 ..< frames {
		for c in 0 ..< min(ad.channels, 2) {
			b := data[(f * ad.channels + c) * bps:]
			v: f32
			switch {
			case ad.is_float && bps == 4: v = transmute(f32)le32(b)
			case bps == 1: v = (f32(b[0]) - 128) / 128
			case bps == 2: v = f32(i16(ad.big ? be16(b) : le16(b))) / 32768
			case bps == 3: v = f32(i32(u32(b[0]) << 8 | u32(b[1]) << 16 | u32(b[2]) << 24) >> 8) / 8388608
			case bps == 4: v = f32(i32(le32(b))) / 2147483648
			}
			append(&ad.tmp, v)
		}
	}
	ch := min(ad.channels, 2)
	step := f64(ad.rate) / audio.SAMPLE_RATE
	n := len(ad.tmp) / ch
	for ad.pos < f64(n - 1) {
		i := int(ad.pos)
		fr := f32(ad.pos - f64(i))
		l := ad.tmp[i * ch] * (1 - fr) + ad.tmp[(i + 1) * ch] * fr
		r := ch == 2 ? ad.tmp[i * ch + 1] * (1 - fr) + ad.tmp[(i + 1) * ch + 1] * fr : l
		append(out, l, r)
		ad.pos += step
	}
	ad.pos -= f64(max(n - 1, 0))
	return true
}

audio_decoder_reset :: proc(ad: ^Audio_Decoder) {ad.pos = 0}
audio_decoder_destroy :: proc(ad: ^Audio_Decoder) {
	if ad == nil do return
	delete(ad.tmp)
	free(ad)
}
