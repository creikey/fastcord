c :: #import "fc_crypto";
sum :: (h: c.Hash, out: []u8, msg: []u8, key: []u8) { c.fc_hmac_sha256(key.data, xx key.count, msg.data, xx msg.count, out.data); }
