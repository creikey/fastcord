#import "Basic";
c :: #import "fc_crypto";
Context_GCM :: c.Aead;
init_gcm :: (x: *Context_GCM, key: []u8) { c.aead_init(x, 0, key); }
reset_gcm :: (x: *Context_GCM) { c.fc_aead_reset(x.ctx.data); }
seal_gcm :: (x: *Context_GCM, dst: []u8, tag: []u8, iv: []u8, aad: []u8, pt: []u8) { c.aead_seal(x, dst, tag, iv, aad, pt); }
open_gcm :: (x: *Context_GCM, dst: []u8, iv: []u8, aad: []u8, ct: []u8, tag: []u8) -> bool { return c.aead_open(x, dst, iv, aad, ct, tag); }
Context_CTR :: struct { key: [32]u8; klen: int; iv: [16]u8; }
init_ctr :: (x: *Context_CTR, key: []u8, iv: []u8) { memcpy(x.key.data, key.data, key.count); x.klen = key.count; memcpy(x.iv.data, iv.data, 16); }
xor_bytes_ctr :: (x: *Context_CTR, dst: []u8, src: []u8) { c.fc_aes_ctr(x.key.data, xx x.klen, x.iv.data, src.data, dst.data, xx src.count); }
reset_ctr :: (x: *Context_CTR) { c.zero_explicit(x, size_of(Context_CTR)); }
