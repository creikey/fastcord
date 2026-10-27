#import "Basic";
#import "fc";
c :: #import "fc_crypto";
Algorithm :: c.Hash;
Context :: c.Hash_Context;
init :: (x: *Context, a: Algorithm) { x.data.count = 0; }
update :: (x: *Context, b: []u8) { c.hash_update(x, b); }
final :: (x: *Context, out: []u8) { c.fc_sha256(x.data.data, xx x.data.count, out.data); array_free(x.data); x.data = .[]; }
hash_string :: (a: Algorithm, s: string, allocator := context.allocator) -> []u8 {
    out := make_slice(u8, 32, allocator);
    c.fc_sha256(s.data, xx s.count, out.data);
    return out;
}
