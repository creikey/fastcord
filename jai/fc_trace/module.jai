// Stack traces from libc's backtrace(), symbolized with backtrace_symbols.
#import "Basic";
#import "fc";
libc :: #system_library "libc";
backtrace :: (buf: **void, n: s32) -> s32 #foreign libc;
backtrace_symbols :: (buf: **void, n: s32) -> **u8 #foreign libc;
Capture_Entry :: u64;
Frame :: struct { procedure: string; file_path: string; line: int; }
capture :: () -> []Capture_Entry {
    buf: [64]*void;
    n := backtrace(buf.data, 64);
    out := NewArray(n, Capture_Entry,, temp);
    for 0..n-1 out[it] = cast(u64) buf[it];
    return out;
}
resolve :: (entries: []Capture_Entry, allocator := context.allocator) -> []Frame, *void {
    syms := backtrace_symbols(cast(**void) entries.data, xx entries.count);
    push_allocator(allocator);
    out := NewArray(entries.count, Frame);
    if syms for 0..entries.count-1 out[it].procedure = copy_string(to_string(syms[it]));
    return out, null;
}
print :: (frames: []Frame) { for frames write_string(tprint("  %\n", it.procedure), to_standard_error = true); }
