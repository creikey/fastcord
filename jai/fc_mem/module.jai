#import "Basic";
Basic :: #import "Basic";
#import "fc";
#import "Flat_Pool";
Allocator_Error :: enum { None; Out_Of_Memory; Invalid_Pointer; Invalid_Argument; Mode_Not_Implemented; }
alloc :: (size: int, alignment := 16, allocator := context.allocator) -> *void, Allocator_Error {
    push_allocator(allocator);
    p := Basic.alloc(size);
    memset(p, 0, size);
    return p, ifx p then .None else .Out_Of_Memory;
}
alloc_bytes :: (size: int, alignment := 16, allocator := context.allocator) -> []u8, Allocator_Error {
    p, e := alloc(size, alignment, allocator);
    b: []u8; b.data = p; b.count = size;
    return b, e;
}
free :: (p: *void, allocator := context.allocator) -> Allocator_Error { push_allocator(allocator); Basic.free(p); return .None; }
copy :: inline (dst: *void, src: *void, n: int) -> *void { memcpy(dst, src, n); return dst; }
copy_non_overlapping :: copy;
zero_slice :: inline (a: []$T) { memset(a.data, 0, a.count * size_of(T)); }
ptr_offset :: inline (p: *$T, n: int) -> *T { return p + n; }
// A growing arena: every allocation lives until reset or destroy.
Dynamic_Arena :: Flat_Pool;
dynamic_arena_init :: (a: *Dynamic_Arena) {}
dynamic_arena_allocator :: (a: *Dynamic_Arena) -> Allocator { return .{flat_pool_allocator_proc, a}; }
dynamic_arena_reset :: (a: *Dynamic_Arena) { reset(a, overwrite_memory = false); }
dynamic_arena_destroy :: (a: *Dynamic_Arena) { fini(a); }
