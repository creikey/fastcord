#import "Basic";
#import "fc";
encode :: (b: []u8, allocator := context.allocator) -> []u8 {
    D :: "0123456789abcdef";
    push_allocator(allocator);
    r := NewArray(b.count * 2, u8, false);
    for b { r[it_index*2] = D[it >> 4]; r[it_index*2+1] = D[it & 15]; }
    return r;
}
