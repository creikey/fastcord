// Growing arenas (Flat_Pool) that, like Odin's virtual arenas, may be shared between threads.
#import "Basic";
#import "Flat_Pool";
mem :: #import "fc_mem";
sync :: #import "fc_sync";
Arena :: struct { pool: Flat_Pool; mu: sync.Mutex; }
arena_init_growing :: (a: *Arena, reserved := 0) -> mem.Allocator_Error { return .None; }
arena_init_static :: (a: *Arena, reserved := 0) -> mem.Allocator_Error { return .None; }
arena_allocator :: (a: *Arena) -> Allocator { return .{arena_proc, a}; }
arena_free_all :: (a: *Arena) { sync.mutex_lock(*a.mu); reset(*a.pool, overwrite_memory = false); sync.mutex_unlock(*a.mu); }
arena_destroy :: (a: *Arena) { fini(*a.pool); }
arena_proc :: (mode: Allocator_Mode, size: s64, old_size: s64, old: *void, data: *void) -> *void {
    a := cast(*Arena) data;
    sync.mutex_lock(*a.mu);
    defer sync.mutex_unlock(*a.mu);
    return flat_pool_allocator_proc(mode, size, old_size, old, *a.pool);
}
