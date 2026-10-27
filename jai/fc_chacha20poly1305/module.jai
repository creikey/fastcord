c :: #import "fc_crypto";
Context :: c.Aead;
init_xchacha :: (x: *Context, key: []u8, impl: $T) { c.aead_init(x, 1, key); }
reset :: (x: *Context) { c.fc_aead_reset(x.ctx.data); }
seal :: (x: *Context, dst: []u8, tag: []u8, iv: []u8, aad: []u8, pt: []u8) { c.aead_seal(x, dst, tag, iv, aad, pt); }
open :: (x: *Context, dst: []u8, iv: []u8, aad: []u8, ct: []u8, tag: []u8) -> bool { return c.aead_open(x, dst, iv, aad, ct, tag); }
