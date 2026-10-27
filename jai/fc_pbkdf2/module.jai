c :: #import "fc_crypto";
derive :: (h: c.Hash, password: []u8, salt: []u8, iterations: u32, dst: []u8) { c.fc_pbkdf2_sha256(password.data, xx password.count, salt.data, xx salt.count, iterations, dst.data, xx dst.count); }
