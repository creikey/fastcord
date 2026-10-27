#import "Basic";
c :: #import "fc_crypto";
Private_Key :: c.Key;
Public_Key :: c.Key;
private_key_set_bytes :: (k: *Private_Key, curve: c.Curve, b: []u8) -> bool {
    if b.count != 32 return false;
    memcpy(k.priv.data, b.data, 32);
    k.ok = c.fc_p256_public(k.priv.data, k.pub.data) == 1;
    return k.ok;
}
private_key_public_bytes :: (k: *Private_Key, out: []u8) { memcpy(out.data, k.pub.data, 65); }
private_key_clear :: (k: *Private_Key) { c.zero_explicit(k, size_of(Private_Key)); }
public_key_set_bytes :: (k: *Public_Key, curve: c.Curve, b: []u8) -> bool {
    if b.count != 65 || c.fc_p256_valid_public(b.data, 65) != 1 return false;
    memcpy(k.pub.data, b.data, 65); k.ok = true;
    return true;
}
public_key_clear :: (k: *Public_Key) { c.zero_explicit(k, size_of(Public_Key)); }
ecdh :: (sk: *Private_Key, pk: *Public_Key, out: []u8) -> bool { return c.fc_p256_ecdh(sk.priv.data, pk.pub.data, 65, out.data) == 1; }
