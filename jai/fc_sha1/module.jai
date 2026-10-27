#import "Basic";
c :: #import "fc_crypto";
DIGEST_SIZE :: 20;
Context :: c.Hash_Context;
init :: (x: *Context) { x.data.count = 0; }
update :: (x: *Context, b: []u8) { c.hash_update(x, b); }
final :: (x: *Context, out: []u8) { c.fc_sha1(x.data.data, xx x.data.count, out.data); array_free(x.data); x.data = .[]; }
