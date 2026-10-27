#import "Basic";
#import "fc";
B :: #import "Base64";
encode :: (b: []u8, allocator := context.allocator) -> string { push_allocator(allocator); return B.base64_encode(as_string(b)); }
decode :: (s: string, allocator := context.allocator) -> []u8, *void {
    push_allocator(allocator);
    r, ok := B.base64_decode(s);
    return to_bytes(r), ifx ok then null else cast(*void) 1;
}
