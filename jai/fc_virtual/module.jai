#import "Basic";
#import "Flat_Pool";
mem :: #import "fc_mem";
Arena :: Flat_Pool;
arena_init_growing :: (a: *Arena, reserved := 0) -> mem.Allocator_Error { return .None; }
arena_init_static :: (a: *Arena, reserved := 0) -> mem.Allocator_Error { return .None; }
arena_allocator :: (a: *Arena) -> Allocator { return .{flat_pool_allocator_proc, a}; }
arena_free_all :: (a: *Arena) { reset(a, overwrite_memory = false); }
arena_destroy :: (a: *Arena) { fini(a); }
