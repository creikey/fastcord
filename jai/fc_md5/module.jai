#import "Basic";
c :: #import "fc_crypto";
DIGEST_SIZE :: 16;
Context :: c.Hash_Context;
init :: (x: *Context) { x.data.count = 0; }
update :: (x: *Context, b: []u8) { c.hash_update(x, b); }
final :: (x: *Context, out: []u8) { c.fc_md5(x.data.data, xx x.data.count, out.data); array_free(x.data); x.data = .{}; }
