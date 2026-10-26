package opus

// Official RFC 6716 / RFC 8251 decoder conformance vectors (gated).
//
// Not checked in. To run, unpack opus_testvectors-rfc8251.tar.gz from
// opus-codec.org somewhere and point OPUS_TESTVECTORS at the directory that
// holds testvector01.bit ... testvector12.bit / .dec / m.dec:
//
//   OPUS_TESTVECTORS=/path/to/opus_newvectors odin test src/opus -collection:fc=src
//
// Mirrors tests/run_vectors.sh: every vector is decoded at 48 kHz stereo and
// compared to testvectorNN.dec with opus_compare -s, then at 48 kHz mono and
// compared to testvectorNN.dec or testvectorNNm.dec (either may pass), with
// the stored final range checked on every packet.

import "core:fmt"
import "core:math"
import "core:os"
import "core:testing"

@(test)
test_rfc8251_vectors :: proc(t: ^testing.T) {
	dir := os.get_env("OPUS_TESTVECTORS", context.temp_allocator)
	if dir == "" {
		fmt.println("test_rfc8251_vectors: OPUS_TESTVECTORS not set, skipping")
		return
	}
	found := 0
	for v in 1 ..= 12 {
		bit_path := fmt.tprintf("%s/testvector%02d.bit", dir, v)
		bits, ok := os.read_entire_file(bit_path, context.temp_allocator)
		if !ok do continue
		found += 1
		ref, ok2 := os.read_entire_file(fmt.tprintf("%s/testvector%02d.dec", dir, v), context.temp_allocator)
		testing.expectf(t, ok2, "missing testvector%02d.dec", v)
		if !ok2 do continue
		refm, okm := os.read_entire_file(fmt.tprintf("%s/testvector%02d.m.dec", dir, v), context.temp_allocator)
		if !okm do refm, okm = os.read_entire_file(fmt.tprintf("%s/testvector%02dm.dec", dir, v), context.temp_allocator)

		stereo, rng_bad_s := vector_decode(bits, 2)
		mono, rng_bad_m := vector_decode(bits, 1)
		defer delete(stereo)
		defer delete(mono)
		testing.expectf(t, rng_bad_s == 0 && rng_bad_m == 0, "testvector%02d: %d/%d final range mismatches", v, rng_bad_s, rng_bad_m)
		qs, oks := opus_compare(ref, stereo, 2)
		testing.expectf(t, oks, "testvector%02d stereo FAILS (Q=%.1f)", v, qs)
		qm, okmono := opus_compare(ref, mono, 1)
		if !okmono && okm do qm, okmono = opus_compare(refm, mono, 1)
		testing.expectf(t, okmono, "testvector%02d mono FAILS (Q=%.1f)", v, qm)
		fmt.printfln("testvector%02d: stereo Q=%.1f mono Q=%.1f", v, qs, qm)
	}
	testing.expectf(t, found == 12, "found %d/12 vectors in %s", found, dir)
}

// opus_demo -d 48000 <channels>: .bit is [u32be len][u32be final range][data];
// len 0 = lost packet (PLC at the last packet duration). Returns s16le pcm.
@(private = "file")
vector_decode :: proc(bits: []u8, channels: int) -> (pcm: []u8, range_mismatches: int) {
	dec := new(Decoder)
	defer free(dec)
	decoder_init(dec, 48000, channels)
	out := make([dynamic]u8)
	buf: [5760 * 2]i16
	be32 :: proc(b: []u8) -> u32 {return u32(b[0]) << 24 | u32(b[1]) << 16 | u32(b[2]) << 8 | u32(b[3])}
	for pos := 0; pos + 8 <= len(bits); {
		l := int(be32(bits[pos:]))
		rng := be32(bits[pos + 4:])
		pos += 8
		if pos + l > len(bits) do break
		pkt := bits[pos:pos + l]
		pos += l
		n: int
		err: Error
		if l == 0 {
			d := max(decoder_last_packet_duration(dec), 960)
			n, err = decode_i16(dec, nil, buf[:d * channels])
		} else {
			n, err = decode_i16(dec, pkt, buf[:])
			if err == .None && decoder_final_range(dec) != rng do range_mismatches += 1
		}
		if err != .None || n <= 0 do continue
		for i in 0 ..< n * channels {
			s := u16(buf[i])
			append(&out, u8(s), u8(s >> 8))
		}
	}
	return out[:], range_mismatches
}

// Port of src/opus_compare.c at 48 kHz. ref is always read as stereo (and
// downmixed for a mono comparison), as in the original tool.
@(private = "file")
CMP_NBANDS :: 21
@(private = "file")
CMP_NFREQS :: 240
@(private = "file")
CMP_WIN :: 480
@(private = "file")
CMP_STEP :: 120
@(private = "file", rodata)
cmp_bands := [CMP_NBANDS + 1]int{0, 2, 4, 6, 8, 10, 12, 14, 16, 20, 24, 28, 32, 40, 48, 56, 68, 80, 96, 120, 156, 200}

@(private = "file")
read_pcm16 :: proc(b: []u8, nch: int) -> []f32 {
	n := len(b) / (2 * nch)
	s := make([]f32, n * nch)
	for i in 0 ..< n * nch do s[i] = f32(i16(u16(b[2 * i]) | u16(b[2 * i + 1]) << 8))
	return s
}

@(private = "file")
band_energy :: proc(out: []f32, ps: []f32, bands: []int, nbands: int, in_: []f32, nch: int, nframes: int, window_sz, step: int) {
	window := make([]f32, window_sz)
	c := make([]f32, window_sz)
	s := make([]f32, window_sz)
	x := make([]f32, nch * window_sz)
	defer {delete(window); delete(c); delete(s); delete(x)}
	ps_sz := window_sz / 2
	for j in 0 ..< window_sz {
		window[j] = 0.5 - 0.5 * f32(math.cos(f64(f32(2 * math.PI / f64(window_sz - 1)) * f32(j))))
		c[j] = f32(math.cos(f64(f32(2 * math.PI / f64(window_sz)) * f32(j))))
		s[j] = f32(math.sin(f64(f32(2 * math.PI / f64(window_sz)) * f32(j))))
	}
	for xi in 0 ..< nframes {
		for ci in 0 ..< nch do for k in 0 ..< window_sz do x[ci * window_sz + k] = window[k] * in_[(xi * step + k) * nch + ci]
		xj := 0
		for bi in 0 ..< nbands {
			p: [2]f32
			for ; xj < bands[bi + 1]; xj += 1 {
				for ci in 0 ..< nch {
					re, im: f32
					ti := 0
					for k in 0 ..< window_sz {
						re += c[ti] * x[ci * window_sz + k]
						im -= s[ti] * x[ci * window_sz + k]
						ti += xj
						if ti >= window_sz do ti -= window_sz
					}
					v := re * re + im * im + 100000
					ps[(xi * ps_sz + xj) * nch + ci] = v
					p[ci] += v
				}
			}
			if out != nil {
				for ci in 0 ..< nch do out[(xi * nbands + bi) * nch + ci] = p[ci] / f32(bands[bi + 1] - bands[bi])
			}
		}
	}
}

// Returns the Opus quality metric Q and whether the vector passes (Q >= 0).
@(private = "file")
opus_compare :: proc(ref_bytes, test_bytes: []u8, nch: int) -> (f32, bool) {
	x := read_pcm16(ref_bytes, 2)
	defer delete(x)
	xlength := len(x) / 2
	if nch == 1 do for i in 0 ..< xlength do x[i] = 0.5 * (x[2 * i] + x[2 * i + 1])
	y := read_pcm16(test_bytes, nch)
	defer delete(y)
	ylength := len(y) / nch
	if xlength != ylength || xlength < CMP_WIN do return -100, false
	nframes := (xlength - CMP_WIN + CMP_STEP) / CMP_STEP
	xb := make([]f32, nframes * CMP_NBANDS * nch)
	X := make([]f32, nframes * CMP_NFREQS * nch)
	Y := make([]f32, nframes * CMP_NFREQS * nch)
	defer {delete(xb); delete(X); delete(Y)}
	band_energy(xb, X, cmp_bands[:], CMP_NBANDS, x, nch, nframes, CMP_WIN, CMP_STEP)
	band_energy(nil, Y, cmp_bands[:], CMP_NBANDS, y, nch, nframes, CMP_WIN, CMP_STEP)
	for xi in 0 ..< nframes {
		for bi in 1 ..< CMP_NBANDS do for ci in 0 ..< nch do xb[(xi * CMP_NBANDS + bi) * nch + ci] += 0.1 * xb[(xi * CMP_NBANDS + bi - 1) * nch + ci]
		for bi := CMP_NBANDS - 2; bi >= 0; bi -= 1 do for ci in 0 ..< nch do xb[(xi * CMP_NBANDS + bi) * nch + ci] += 0.03 * xb[(xi * CMP_NBANDS + bi + 1) * nch + ci]
		if xi > 0 {
			for bi in 0 ..< CMP_NBANDS do for ci in 0 ..< nch do xb[(xi * CMP_NBANDS + bi) * nch + ci] += 0.5 * xb[((xi - 1) * CMP_NBANDS + bi) * nch + ci]
		}
		if nch == 2 {
			for bi in 0 ..< CMP_NBANDS {
				l := xb[(xi * CMP_NBANDS + bi) * nch + 0]
				r := xb[(xi * CMP_NBANDS + bi) * nch + 1]
				xb[(xi * CMP_NBANDS + bi) * nch + 0] += 0.01 * r
				xb[(xi * CMP_NBANDS + bi) * nch + 1] += 0.01 * l
			}
		}
		for bi in 0 ..< CMP_NBANDS {
			for xj in cmp_bands[bi] ..< cmp_bands[bi + 1] {
				for ci in 0 ..< nch {
					X[(xi * CMP_NFREQS + xj) * nch + ci] += 0.1 * xb[(xi * CMP_NBANDS + bi) * nch + ci]
					Y[(xi * CMP_NFREQS + xj) * nch + ci] += 0.1 * xb[(xi * CMP_NBANDS + bi) * nch + ci]
				}
			}
		}
	}
	for bi in 0 ..< CMP_NBANDS {
		for xj in cmp_bands[bi] ..< cmp_bands[bi + 1] {
			for ci in 0 ..< nch {
				xtmp := X[xj * nch + ci]
				ytmp := Y[xj * nch + ci]
				for xi in 1 ..< nframes {
					xtmp2 := X[(xi * CMP_NFREQS + xj) * nch + ci]
					ytmp2 := Y[(xi * CMP_NFREQS + xj) * nch + ci]
					X[(xi * CMP_NFREQS + xj) * nch + ci] += xtmp
					Y[(xi * CMP_NFREQS + xj) * nch + ci] += ytmp
					xtmp = xtmp2
					ytmp = ytmp2
				}
			}
		}
	}
	max_compare := cmp_bands[CMP_NBANDS]
	err: f64 = 0
	for xi in 0 ..< nframes {
		Ef: f64 = 0
		for bi in 0 ..< CMP_NBANDS {
			Eb: f64 = 0
			for xj := cmp_bands[bi]; xj < cmp_bands[bi + 1] && xj < max_compare; xj += 1 {
				for ci in 0 ..< nch {
					re := Y[(xi * CMP_NFREQS + xj) * nch + ci] / X[(xi * CMP_NFREQS + xj) * nch + ci]
					im := f32(f64(re) - math.ln(f64(re)) - 1)
					if xj >= 79 && xj <= 81 do im *= 0.1
					if xj == 80 do im *= 0.1
					Eb += f64(im)
				}
			}
			Eb /= f64((cmp_bands[bi + 1] - cmp_bands[bi]) * nch)
			Ef += Eb * Eb
		}
		Ef /= CMP_NBANDS
		Ef *= Ef
		err += Ef * Ef
	}
	err = math.pow(err / f64(nframes), 1.0 / 16)
	Q := f32(100 * (1 - 0.5 * math.ln(1 + err) / math.ln(f64(1.13))))
	return Q, Q >= 0
}
