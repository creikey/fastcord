#import "Basic";
c :: #import "fc_crypto";
DIGEST_SIZE_256 :: 32;
Context_256 :: c.Hash_Context;
init_256 :: (x: *Context_256) { x.data.count = 0; }
update :: (x: *Context_256, b: []u8) { c.hash_update(x, b); }
final :: (x: *Context_256, out: []u8) { c.fc_sha256(x.data.data, xx x.data.count, out.data); array_free(x.data); x.data = .{}; }
