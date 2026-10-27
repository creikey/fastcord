// QR code encoder: a port of qr.js (Kazuhiko Arase's QRCode for JavaScript, as
// bundled by qrcode.react 1.x), which the official client uses for the QR login
// panel: `new QRCode(-1, ErrorCorrectLevel[level])`, `addData(text)`, `make()`.
// Byte mode only. The version is the smallest that fits (qr.js's loop, which
// stops at 39), and the mask is chosen with qr.js's own penalty (getLostPoint),
// which differs from the ISO one, so the module matrix matches the client's
// exactly (tests compare it with the bundle's output).

Level :: enum u8 {
	L;
	M;
	Q;
	H;
}
#scope_module

// qr.js QRErrorCorrectLevel values (the format bits), indexed by Level: L 1, M 0, Q 3, H 2.
LEVEL_BITS :: u32.[1, 0, 3, 2];
#scope_export

MAX_MODULES :: 4 * 40 + 17;

// Code: size x size modules, row-major, true = dark.
Code_ :: struct {
	size: int;
	version: int;
	mask: int;
	modules: [MAX_MODULES * MAX_MODULES]bool;
}

dark :: (c: *Code_, row: int, col: int) -> bool {
	return c.modules[row * c.size + col];
}

// encode builds the code for text in byte mode. ok is false when the text does
// not fit (qr.js would throw).
encode :: (text: string, level: Level = .M) -> Code_, bool {
	c: Code_;
	ok: bool;
	data := transmute([]u8, text);
	version := 0;
	for v: 1..39 {
		cap := data_capacity(v, level);
		bits := 4 + length_bits(v) + 8 * len(data);
		if bits <= 8 * cap {
			version = v;
			break;
		}
		version = v + 1;
	}
	if version > 40 || 4 + length_bits(version) + 8 * len(data) > 8 * data_capacity(version, level) { return .{}, false; }
	codewords, cok := create_data(version, level, data);
	if !cok { return .{}, false; }
	defer delete(codewords);
	c.version = version;
	c.size = 4 * version + 17;
	// getBestMaskPattern: the lowest getLostPoint, the first on ties
	best: float64 = 0;
	best_mask := 0;
	for m: 0..7 {
		make_impl(*c, level, codewords, m, true);
		p := lost_point(*c);
		if m == 0 || best > p {
			best = p;
			best_mask = m;
		}
	}
	make_impl(*c, level, codewords, best_mask, false);
	c.mask = best_mask;
	return c, true;
}
#scope_module

// ---- tables ----

// ---- tables ----

RS_BLOCK_TABLE := []int.[
	.[1, 26, 19], .[1, 26, 16], .[1, 26, 13], .[1, 26, 9],
	.[1, 44, 34], .[1, 44, 28], .[1, 44, 22], .[1, 44, 16],
	.[1, 70, 55], .[1, 70, 44], .[2, 35, 17], .[2, 35, 13],
	.[1, 100, 80], .[2, 50, 32], .[2, 50, 24], .[4, 25, 9],
	.[1, 134, 108], .[2, 67, 43], .[2, 33, 15, 2, 34, 16], .[2, 33, 11, 2, 34, 12],
	.[2, 86, 68], .[4, 43, 27], .[4, 43, 19], .[4, 43, 15],
	.[2, 98, 78], .[4, 49, 31], .[2, 32, 14, 4, 33, 15], .[4, 39, 13, 1, 40, 14],
	.[2, 121, 97], .[2, 60, 38, 2, 61, 39], .[4, 40, 18, 2, 41, 19], .[4, 40, 14, 2, 41, 15],
	.[2, 146, 116], .[3, 58, 36, 2, 59, 37], .[4, 36, 16, 4, 37, 17], .[4, 36, 12, 4, 37, 13],
	.[2, 86, 68, 2, 87, 69], .[4, 69, 43, 1, 70, 44], .[6, 43, 19, 2, 44, 20], .[6, 43, 15, 2, 44, 16],
	.[4, 101, 81], .[1, 80, 50, 4, 81, 51], .[4, 50, 22, 4, 51, 23], .[3, 36, 12, 8, 37, 13],
	.[2, 116, 92, 2, 117, 93], .[6, 58, 36, 2, 59, 37], .[4, 46, 20, 6, 47, 21], .[7, 42, 14, 4, 43, 15],
	.[4, 133, 107], .[8, 59, 37, 1, 60, 38], .[8, 44, 20, 4, 45, 21], .[12, 33, 11, 4, 34, 12],
	.[3, 145, 115, 1, 146, 116], .[4, 64, 40, 5, 65, 41], .[11, 36, 16, 5, 37, 17], .[11, 36, 12, 5, 37, 13],
	.[5, 109, 87, 1, 110, 88], .[5, 65, 41, 5, 66, 42], .[5, 54, 24, 7, 55, 25], .[11, 36, 12],
	.[5, 122, 98, 1, 123, 99], .[7, 73, 45, 3, 74, 46], .[15, 43, 19, 2, 44, 20], .[3, 45, 15, 13, 46, 16],
	.[1, 135, 107, 5, 136, 108], .[10, 74, 46, 1, 75, 47], .[1, 50, 22, 15, 51, 23], .[2, 42, 14, 17, 43, 15],
	.[5, 150, 120, 1, 151, 121], .[9, 69, 43, 4, 70, 44], .[17, 50, 22, 1, 51, 23], .[2, 42, 14, 19, 43, 15],
	.[3, 141, 113, 4, 142, 114], .[3, 70, 44, 11, 71, 45], .[17, 47, 21, 4, 48, 22], .[9, 39, 13, 16, 40, 14],
	.[3, 135, 107, 5, 136, 108], .[3, 67, 41, 13, 68, 42], .[15, 54, 24, 5, 55, 25], .[15, 43, 15, 10, 44, 16],
	.[4, 144, 116, 4, 145, 117], .[17, 68, 42], .[17, 50, 22, 6, 51, 23], .[19, 46, 16, 6, 47, 17],
	.[2, 139, 111, 7, 140, 112], .[17, 74, 46], .[7, 54, 24, 16, 55, 25], .[34, 37, 13],
	.[4, 151, 121, 5, 152, 122], .[4, 75, 47, 14, 76, 48], .[11, 54, 24, 14, 55, 25], .[16, 45, 15, 14, 46, 16],
	.[6, 147, 117, 4, 148, 118], .[6, 73, 45, 14, 74, 46], .[11, 54, 24, 16, 55, 25], .[30, 46, 16, 2, 47, 17],
	.[8, 132, 106, 4, 133, 107], .[8, 75, 47, 13, 76, 48], .[7, 54, 24, 22, 55, 25], .[22, 45, 15, 13, 46, 16],
	.[10, 142, 114, 2, 143, 115], .[19, 74, 46, 4, 75, 47], .[28, 50, 22, 6, 51, 23], .[33, 46, 16, 4, 47, 17],
	.[8, 152, 122, 4, 153, 123], .[22, 73, 45, 3, 74, 46], .[8, 53, 23, 26, 54, 24], .[12, 45, 15, 28, 46, 16],
	.[3, 147, 117, 10, 148, 118], .[3, 73, 45, 23, 74, 46], .[4, 54, 24, 31, 55, 25], .[11, 45, 15, 31, 46, 16],
	.[7, 146, 116, 7, 147, 117], .[21, 73, 45, 7, 74, 46], .[1, 53, 23, 37, 54, 24], .[19, 45, 15, 26, 46, 16],
	.[5, 145, 115, 10, 146, 116], .[19, 75, 47, 10, 76, 48], .[15, 54, 24, 25, 55, 25], .[23, 45, 15, 25, 46, 16],
	.[13, 145, 115, 3, 146, 116], .[2, 74, 46, 29, 75, 47], .[42, 54, 24, 1, 55, 25], .[23, 45, 15, 28, 46, 16],
	.[17, 145, 115], .[10, 74, 46, 23, 75, 47], .[10, 54, 24, 35, 55, 25], .[19, 45, 15, 35, 46, 16],
	.[17, 145, 115, 1, 146, 116], .[14, 74, 46, 21, 75, 47], .[29, 54, 24, 19, 55, 25], .[11, 45, 15, 46, 46, 16],
	.[13, 145, 115, 6, 146, 116], .[14, 74, 46, 23, 75, 47], .[44, 54, 24, 7, 55, 25], .[59, 46, 16, 1, 47, 17],
	.[12, 151, 121, 7, 152, 122], .[12, 75, 47, 26, 76, 48], .[39, 54, 24, 14, 55, 25], .[22, 45, 15, 41, 46, 16],
	.[6, 151, 121, 14, 152, 122], .[6, 75, 47, 34, 76, 48], .[46, 54, 24, 10, 55, 25], .[2, 45, 15, 64, 46, 16],
	.[17, 152, 122, 4, 153, 123], .[29, 74, 46, 14, 75, 47], .[49, 54, 24, 10, 55, 25], .[24, 45, 15, 46, 46, 16],
	.[4, 152, 122, 18, 153, 123], .[13, 74, 46, 32, 75, 47], .[48, 54, 24, 14, 55, 25], .[42, 45, 15, 32, 46, 16],
	.[20, 147, 117, 4, 148, 118], .[40, 75, 47, 7, 76, 48], .[43, 54, 24, 22, 55, 25], .[10, 45, 15, 67, 46, 16],
	.[19, 148, 118, 6, 149, 119], .[18, 75, 47, 31, 76, 48], .[34, 54, 24, 34, 55, 25], .[20, 45, 15, 61, 46, 16]
];

PATTERN_POSITION_TABLE := []int.[
	.[], .[6, 18], .[6, 22], .[6, 26], .[6, 30], .[6, 34], .[6, 22, 38], .[6, 24, 42], .[6, 26, 46], .[6, 28, 50],
	.[6, 30, 54], .[6, 32, 58], .[6, 34, 62], .[6, 26, 46, 66], .[6, 26, 48, 70], .[6, 26, 50, 74], .[6, 30, 54, 78],
	.[6, 30, 56, 82], .[6, 30, 58, 86], .[6, 34, 62, 90], .[6, 28, 50, 72, 94], .[6, 26, 50, 74, 98],
	.[6, 30, 54, 78, 102], .[6, 28, 54, 80, 106], .[6, 32, 58, 84, 110], .[6, 30, 58, 86, 114],
	.[6, 34, 62, 90, 118], .[6, 26, 50, 74, 98, 122], .[6, 30, 54, 78, 102, 126], .[6, 26, 52, 78, 104, 130],
	.[6, 30, 56, 82, 108, 134], .[6, 34, 60, 86, 112, 138], .[6, 30, 58, 86, 114, 142], .[6, 34, 62, 90, 118, 146],
	.[6, 30, 54, 78, 102, 126, 150], .[6, 24, 50, 76, 102, 128, 154], .[6, 28, 54, 80, 106, 132, 158],
	.[6, 32, 58, 84, 110, 136, 162], .[6, 26, 54, 82, 110, 138, 166], .[6, 30, 58, 86, 114, 142, 170]
];

// RS_BLOCK_TABLE row order per version is L, M, Q, H.
rs_row :: (version: int, level: Level) -> []int {
	idx: int;
	if level == {
	case .L;
		idx = 0;
	case .M;
		idx = 1;
	case .Q;
		idx = 2;
	case .H;
		idx = 3;
	}
	return RS_BLOCK_TABLE[(version - 1) * 4 + idx];
}

data_capacity :: (version: int, level: Level) -> int {
	t := rs_row(version, level);
	n := 0;
	{ i := 0;
	while i < len(t) { n += t[i] * t[i + 2];  i += 3; } }
	return n;
}

// byte-mode character count bits
length_bits :: (version: int) -> int {
	return ifx version < 10 then 8 else 16;
}

// ---- GF(256) ----

Gf :: struct {
	exp: [256]int;
	log: [256]int;
}

gf_tables :: () -> Gf {
	g: Gf;
	for i: 0..7 { g.exp[i] = 1 << (cast(u64)(i)); }
	for i: 8..255 { g.exp[i] = g.exp[i - 4] ^ g.exp[i - 5] ^ g.exp[i - 6] ^ g.exp[i - 8]; }
	for i: 0..254 { g.log[g.exp[i]] = i; }
	return g;
}

gexp :: (g: *Gf, n_in: int) -> int {
	n := n_in;
	while n < 0 { n += 255; }
	while n >= 256 { n -= 255; }
	return g.exp[n];
}

// polynomial (qr.js QRPolynomial): leading zeros dropped, `shift` zeros appended
poly_new :: (num: []int, shift: int) -> [..]int {
	off := 0;
	while off < len(num) && num[off] == 0 { off += 1; }
	p := make_dynamic(int, len(num) - off + shift, len(num) - off + shift);
	for i: 0..(len(num) - off)-1 { p[i] = num[i + off]; }
	return p;
}

poly_multiply :: (g: *Gf, a: []int, b: []int) -> [..]int {
	n := make_slice(int, len(a) + len(b) - 1);
	defer delete(n);
	for i: 0..len(a)-1 { for j: 0..len(b)-1 { n[i + j] ^= gexp(g, g.log[a[i]] + g.log[b[j]]); } }
	return poly_new(n, 0);
}

poly_mod :: (g: *Gf, a: []int, b: []int) -> [..]int {
	cur := poly_new(a, 0);
	while len(cur) - len(b) >= 0 {
		ratio := g.log[cur[0]] - g.log[b[0]];
		next := make_slice(int, len(cur));
		for i: 0..len(cur)-1 { next[i] = cur[i]; }
		for i: 0..len(b)-1 { next[i] ^= gexp(g, g.log[b[i]] + ratio); }
		delete(cur);
		cur = poly_new(next, 0);
		delete(next);
	}
	return cur;
}

error_correct_poly :: (g: *Gf, ec_len: int) -> [..]int {
	a := poly_new(int.[1], 0);
	for i: 0..ec_len-1 {
		b := int.[1, gexp(g, i)];
		m := poly_multiply(g, view(a), view(b));
		delete(a);
		a = m;
	}
	return a;
}

// ---- data ----

Bits :: struct {
	buf: [..]u8;
	n: int;
}

put_bit :: (b: *Bits, on: bool) {
	if len(b.buf) <= b.n / 8 { append(*b.buf, 0); }
	if on { b.buf[b.n / 8] |= cast(u8) (0x80 >> (cast(u64)(b.n % 8))); }
	b.n += 1;
}

put :: (b: *Bits, v: int, n: int) {
	for i: 0..n-1 { put_bit(b, ((v >> (cast(u64)(n - i - 1))) & 1) == 1); }
}

create_data :: (version: int, level: Level, data: []u8) -> [..]int, bool {
	out: [..]int;
	ok: bool;
	b: Bits;
	defer delete(b.buf);
	put(*b, 4, 4); // MODE_8BIT_BYTE
	put(*b, len(data), length_bits(version));
	for x: data { put(*b, cast(int)(x), 8); }
	total := data_capacity(version, level);
	if b.n > 8 * total { return zero([..]int), false; }
	if b.n + 4 <= 8 * total { put(*b, 0, 4); }
	while b.n % 8 != 0 { put_bit(*b, false); }
	while b.n < 8 * total {
		put(*b, 236, 8);
		if b.n >= 8 * total { break; }
		put(*b, 17, 8);
	}
	return create_bytes(*b, version, level), true;
}

Rs_Block :: struct {
	total, data: int;
}

create_bytes :: (b: *Bits, version: int, level: Level) -> [..]int {
	g := gf_tables();
	t := rs_row(version, level);
	blocks := make_dynamic(Rs_Block, 0, 0, temp);
	{ i := 0;
	while i < len(t) { for _: 0..t[i]-1 { append(*blocks, Rs_Block.{t[i + 1], t[i + 2]}); }  i += 3; } }
	dc := make_slice([]int, len(blocks), temp);
	ec := make_slice([]int, len(blocks), temp);
	offset, max_dc, max_ec := 0, 0, 0;
	for blk, r: blocks {
		dcount := blk.data;
		eccount := blk.total - dcount;
		max_dc = max(max_dc, dcount);
		max_ec = max(max_ec, eccount);
		dc[r] = make_slice(int, dcount, temp);
		for i: 0..dcount-1 { dc[r][i] = 0xff & (cast(int)(b.buf[i + offset])); }
		offset += dcount;
		rs := error_correct_poly(*g, eccount);
		defer delete(rs);
		raw := poly_new(dc[r], len(rs) - 1);
		defer delete(raw);
		mod := poly_mod(*g, view(raw), view(rs));
		defer delete(mod);
		ec[r] = make_slice(int, len(rs) - 1, temp);
		for i: 0..len(ec[r])-1 {
			mi := i + len(mod) - len(ec[r]);
			ec[r][i] = ifx mi >= 0 then mod[mi] else 0;
		}
	}
	out := make_dynamic(int, 0, 0);
	for i: 0..max_dc-1 { for r: 0..len(blocks)-1 { if i < len(dc[r]) { append(*out, dc[r][i]); } } }
	for i: 0..max_ec-1 { for r: 0..len(blocks)-1 { if i < len(ec[r]) { append(*out, ec[r][i]); } } }
	return out;
}

// ---- layout ----

// ---- layout ----

G15 : u32 : 0b10100110111;
G18 : u32 : 0b1111100100101;
G15_MASK : u32 : 0b101010000010010;

bch_digit :: (v_in: u32) -> int {
	v := v_in;
	n := 0;
	while v != 0 {
		n += 1;
		v >>= 1;
	}
	return n;
}

bch_type_info :: (data: u32) -> u32 {
	d := data << 10;
	while bch_digit(d) - bch_digit(G15) >= 0 { d ^= G15 << (cast(u64)(bch_digit(d) - bch_digit(G15))); }
	return ((data << 10) | d) ^ G15_MASK;
}

bch_type_number :: (data: u32) -> u32 {
	d := data << 12;
	while bch_digit(d) - bch_digit(G18) >= 0 { d ^= G18 << (cast(u64)(bch_digit(d) - bch_digit(G18))); }
	return (data << 12) | d;
}

mask_bit :: (mask: int, i: int, j: int) -> bool {
	if mask == {
	case 0;
		return (i + j) % 2 == 0;
	case 1;
		return i % 2 == 0;
	case 2;
		return j % 3 == 0;
	case 3;
		return (i + j) % 3 == 0;
	case 4;
		return (i / 2 + j / 3) % 2 == 0;
	case 5;
		return (i * j) % 2 + (i * j) % 3 == 0;
	case 6;
		return ((i * j) % 2 + (i * j) % 3) % 2 == 0;
	case 7;
		return ((i * j) % 3 + (i + j) % 2) % 2 == 0;
	}
	return false;
}

// make_impl: qr.js makeImpl(test, maskPattern). set tracks which modules are placed.
make_impl :: (c: *Code_, level: Level, data: [..]int, mask: int, test: bool) {
	n := c.size;
	set: [MAX_MODULES * MAX_MODULES]bool;
	for i: 0..(n * n)-1 { c.modules[i] = false; }
	place :: (c: *Code_, set: *[MAX_MODULES * MAX_MODULES]bool, r: int, col: int, v: bool) {
		c.modules[r * c.size + col] = v;
		set.*[r * c.size + col] = true;
	}
	// position probes
	probes := [2]int.[.[0, 0], .[n - 7, 0], .[0, n - 7]];
	for p: probes {
		for r: -1..7 {
			if p[0] + r <= -1 || n <= p[0] + r { continue; }
			for cc: -1..7 {
				if p[1] + cc <= -1 || n <= p[1] + cc { continue; }
				on := (0 <= r && r <= 6 && (cc == 0 || cc == 6)) || (0 <= cc && cc <= 6 && (r == 0 || r == 6)) || (2 <= r && r <= 4 && 2 <= cc && cc <= 4);
				place(c, *set, p[0] + r, p[1] + cc, on);
			}
		}
	}
	// alignment patterns
	pos := PATTERN_POSITION_TABLE[c.version - 1];
	for a: pos {
		for b: pos {
			if set[a * n + b] { continue; }
			for r: -2..2 { for cc: -2..2 {
				on := r == -2 || r == 2 || cc == -2 || cc == 2 || (r == 0 && cc == 0);
				place(c, *set, a + r, b + cc, on);
			} }
		}
	}
	// timing
	for r: 8..(n - 8)-1 { if !set[r * n + 6] { place(c, *set, r, 6, r % 2 == 0); } }
	for cc: 8..(n - 8)-1 { if !set[6 * n + cc] { place(c, *set, 6, cc, cc % 2 == 0); } }
	// type info
	bits := bch_type_info((LEVEL_BITS[cast(int) level] << 3) | (cast(u32)(mask)));
	for i: 0..14 {
		on := !test && ((bits >> (cast(u64)(i))) & 1) == 1;
		if i < 6 { place(c, *set, i, 8, on); } else if i < 8 { place(c, *set, i + 1, 8, on); } else { place(c, *set, n - 15 + i, 8, on); }
	}
	for i: 0..14 {
		on := !test && ((bits >> (cast(u64)(i))) & 1) == 1;
		if i < 8 { place(c, *set, 8, n - i - 1, on); } else if i < 9 { place(c, *set, 8, 15 - i - 1 + 1, on); } else { place(c, *set, 8, 15 - i - 1, on); }
	}
	place(c, *set, n - 8, 8, !test);
	// version info
	if c.version >= 7 {
		vb := bch_type_number(cast(u32)(c.version));
		for i: 0..17 {
			on := !test && ((vb >> (cast(u64)(i))) & 1) == 1;
			place(c, *set, i / 3, i % 3 + n - 8 - 3, on);
		}
		for i: 0..17 {
			on := !test && ((vb >> (cast(u64)(i))) & 1) == 1;
			place(c, *set, i % 3 + n - 8 - 3, i / 3, on);
		}
	}
	// data (mapData)
	inc := -1;
	row := n - 1;
	bit := 7;
	idx := 0;
	{ col := n - 1;
	while col > 0 {
		if col == 6 { col -= 1; }
		while true {
			for k: 0..1 {
				cc := col - k;
				if set[row * n + cc] continue;
				on := false;
				if idx < len(data) { on = ((data[idx] >> (cast(u64)(bit))) & 1) == 1; }
				if mask_bit(mask, row, cc) { on = !on; }
				place(c, *set, row, cc, on);
				bit -= 1;
				if bit == -1 {
					idx += 1;
					bit = 7;
				}
			}
			row += inc;
			if row < 0 || n <= row {
				row -= inc;
				inc = -inc;
				break;
			}
		}
		col -= 2;
} }
}

// lost_point: qr.js QRUtil.getLostPoint (not the ISO penalty).
lost_point :: (c: *Code_) -> float64 {
	n := c.size;
	d :: (c: *Code_, r: int, col: int) -> bool {return c.modules[r * c.size + col];}
	lost := 0;
	for r: 0..n-1 {
		for col: 0..n-1 {
			same := 0;
			v := d(c, r, col);
			for dr: -1..1 {
				if r + dr < 0 || n <= r + dr { continue; }
				for dc: -1..1 {
					if col + dc < 0 || n <= col + dc || (dr == 0 && dc == 0) { continue; }
					if v == d(c, r + dr, col + dc) { same += 1; }
				}
			}
			if same > 5 { lost += 3 + same - 5; }
		}
	}
	for r: 0..(n - 1)-1 {
		for col: 0..(n - 1)-1 {
			k := 0;
			if d(c, r, col) { k += 1; }
			if d(c, r + 1, col) { k += 1; }
			if d(c, r, col + 1) { k += 1; }
			if d(c, r + 1, col + 1) { k += 1; }
			if k == 0 || k == 4 { lost += 3; }
		}
	}
	for r: 0..n-1 {
		for col: 0..(n - 6)-1 {
			if d(c, r, col) && !d(c, r, col + 1) && d(c, r, col + 2) && d(c, r, col + 3) && d(c, r, col + 4) && !d(c, r, col + 5) && d(c, r, col + 6) { lost += 40; }
		}
	}
	for col: 0..n-1 {
		for r: 0..(n - 6)-1 {
			if d(c, r, col) && !d(c, r + 1, col) && d(c, r + 2, col) && d(c, r + 3, col) && d(c, r + 4, col) && !d(c, r + 5, col) && d(c, r + 6, col) { lost += 40; }
		}
	}
	dark_count := 0;
	for i: 0..(n * n)-1 { if c.modules[i] { dark_count += 1; } }
	ratio := abs(100 * cast(float64)(dark_count) / cast(float64)(n) / cast(float64)(n) - 50) / 5;
	return cast(float64)(lost) + 10 * ratio;
}
#scope_export

