// Android: no stack sampler yet, so captures come back empty. sampler_linux.jai's method would work, with the
// arm64 registers and return-address test in place of x86_64's.
Thread_Ref :: struct {
	tid: s32;
}

current_thread :: () -> Thread_Ref { return .{tid = cast(s32) syscall(SYS_gettid)}; }

capture_thread :: (t: Thread_Ref, buf: []u64) -> int { return 0; }

#scope_module

capture_thread_gated :: (t: Thread_Ref, buf: []u64, gate: *s32) -> int, bool { return 0, true; }

timer_make :: () -> *void { return null; }
timer_destroy :: (t: *void) {}
timer_wait :: (t: *void, ns: s64) { sleep_milliseconds(cast(s32) max(ns / 1_000_000, 1)); }

symbolize :: (addr: u64) -> Symbol { return .{}; }
