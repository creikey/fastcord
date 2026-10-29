// The stuck main thread's stack, through the profiler's sampler: a signal, then a scan of its stack (on
// macOS the callers are approximate, see prof/sampler_darwin.jai). Other threads' stacks need Mach or ptrace
// from outside the process, so the report says how to get them.
write_thread_stacks :: (b: *String_Builder, main_tid: int) {
	raw: [48]u64;
	n := prof.capture_thread(main_thread, raw);
	print_to_builder(b, "\nthread % (main)\n", main_tid);
	for array_view(raw, 0, n) {
		sym := prof.symbol_at(it);
		print_to_builder(b, "  %  %:%\n", ifx sym.procedure then sym.procedure else tprint("0x%", formatInt(it, base = 16)), sym.file, sym.line);
	}
	#if OS == .MACOS print_to_builder(b, "for every thread's stack run: sample % 1\n", getpid());
	else print_to_builder(b, "for every thread's stack run: gdb -p % -batch -ex 'thread apply all bt'\n", getpid());
}

main_thread: prof.Thread_Ref; // watchdog_start, on the main thread

#scope_file

getpid :: () -> s32 #foreign libc;
