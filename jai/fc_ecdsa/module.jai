#import "Basic";
#import "fc";
c :: #import "fc_crypto";
e :: #import "fc_ecdh";
Private_Key :: c.Key;
Public_Key :: c.Key;
private_key_set_bytes :: e.private_key_set_bytes;
private_key_public_bytes :: e.private_key_public_bytes;
private_key_clear :: e.private_key_clear;
public_key_set_bytes :: e.public_key_set_bytes;
public_key_clear :: e.public_key_clear;
private_key_bytes :: (k: *Private_Key, out: []u8) { memcpy(out.data, k.priv.data, 32); }
private_key_generate :: (k: *Private_Key, curve: c.Curve) -> bool { k.ok = c.fc_p256_generate(k.priv.data, k.pub.data) == 1; return k.ok; }
sign_asn1 :: (k: *Private_Key, h: c.Hash, msg: []u8, allocator := context.allocator) -> []u8, bool {
    sig: [72]u8;
    n := c.fc_p256_sign(k.priv.data, msg.data, xx msg.count, sig.data);
    if n == 0 return .[], false;
    return clone(sub(sig, 0, n), allocator), true;
}
verify_asn1 :: (k: *Public_Key, h: c.Hash, msg: []u8, sig: []u8) -> bool { return c.fc_p256_verify(k.pub.data, 65, msg.data, xx msg.count, sig.data, xx sig.count) == 1; }
