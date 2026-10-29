/// The `fc-` text form of E2E packets, for carriers that move text: a Discord DM's message content, or a
/// hosted server's DM. It is `fc-` plus canonical unpadded base64url of at most MAX_PACKET bytes, so a
/// packet has exactly one text form and fits one 2000-character message.
#import "Basic";
#import "String";

PREFIX :: "fc-";
MAX_PACKET :: 1497; // 1996 base64url characters.

encode :: (packet: []u8) -> string {
	assert(packet.count <= MAX_PACKET);
	out := alloc_string(PREFIX.count + (packet.count * 4 + 2) / 3);
	memcpy(out.data, PREFIX.data, PREFIX.count);
	o := PREFIX.count;
	acc: u32;
	bits := 0;
	for packet {
		acc = (acc << 8) | it;
		bits += 8;
		while bits >= 6 {
			bits -= 6;
			out[o] = B64[(acc >> bits) & 63];
			o += 1;
		}
	}
	if bits { out[o] = B64[(acc << (6 - bits)) & 63]; o += 1; }
	assert(o == out.count);
	return out;
}

// decode accepts only the one canonical encoding: no padding, no other alphabet, and zero trailing bits.
// The packet is in temp.
decode :: (text: string) -> []u8, bool {
	if !begins_with(text, PREFIX) return .[], false;
	s := text;
	advance(*s, PREFIX.count);
	if s.count % 4 == 1 || s.count > (MAX_PACKET * 4 + 2) / 3 return .[], false;
	out := NewArray(s.count * 3 / 4, u8, false,, temp);
	acc: u32;
	bits := 0;
	o := 0;
	for i: 0..s.count-1 {
		v := B64_INV[s[i]];
		if v == 0xFF return .[], false;
		acc = ((acc << 6) | v) & 0xFFFF;
		bits += 6;
		if bits >= 8 {
			bits -= 8;
			out[o] = xx ((acc >> bits) & 0xFF);
			o += 1;
		}
	}
	if (acc & ((cast(u32) 1 << bits) - 1)) != 0 || o < 2 return .[], false;
	assert(o == out.count);
	return out, true;
}

#scope_file

B64 :: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
B64_INV :: #run b64_inverse();
b64_inverse :: () -> [256]u8 {
	t: [256]u8;
	for *t it.* = 0xFF;
	for i: 0..B64.count-1 t[B64[i]] = xx i;
	return t;
}
