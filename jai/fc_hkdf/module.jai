c :: #import "fc_crypto";
extract :: (h: c.Hash, salt: []u8, ikm: []u8, out: []u8) { c.fc_hkdf_extract(salt.data, xx salt.count, ikm.data, xx ikm.count, out.data); }
expand :: (h: c.Hash, prk: []u8, info: []u8, dst: []u8) { c.fc_hkdf_expand(prk.data, xx prk.count, info.data, xx info.count, dst.data, xx dst.count); }
