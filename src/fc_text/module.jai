/// The `fc-` text form of E2E packets, for carriers that move text: a Discord DM's message content, or a
/// hosted server's DM. It is `fc-` plus canonical unpadded base64url of at most MAX_PACKET bytes, so a
/// packet has exactly one text form and fits one 2000-character message. A larger packet (E2E 5's signed
/// Hello, a long message) goes as the message's last attachment, ATTACHMENT_NAME, and its text is
/// `attached`: ATTACHED and the packet's BLAKE3 hash, which the receiver checks before opening it.
#import "Basic";
#import "String";

PREFIX :: "fc-";
MAX_PACKET :: 1497; // 1996 base64url characters.
MAX_BUNDLE :: 16384; // A prekey bundle, which travels in JSON rather than a message.
ATTACHED :: u8.[0xFC, 0x01]; // No E2E packet starts so: byte 0 is its version.
ATTACHMENT_NAME :: "fc.bin";

attached :: (hash: [32]u8) -> string {
	b: [34]u8;
	memcpy(b.data, ATTACHED.data, 2);
	memcpy(b.data + 2, hash.data, 32);
	return encode(b);
}

// attached_hash: the hash a decoded text names, when it stands for an attached packet.
attached_hash :: (b: []u8) -> [32]u8, bool {
	h: [32]u8;
	if b.count != 34 || b[0] != ATTACHED[0] || b[1] != ATTACHED[1] return h, false;
	memcpy(h.data, b.data + 2, 32);
	return h, true;
}

encode :: (packet: []u8) -> string {
	assert(packet.count <= MAX_BUNDLE);
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
decode :: (text: string, max := MAX_PACKET) -> []u8, bool {
	if !begins_with(text, PREFIX) return .[], false;
	s := text;
	advance(*s, PREFIX.count);
	if s.count % 4 == 1 || s.count > (max * 4 + 2) / 3 return .[], false;
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
