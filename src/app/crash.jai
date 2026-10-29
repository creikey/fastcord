// Crash reports. A crash (a fatal signal, an unhandled Windows exception) writes <data>/logs/crash.txt with
// the version, the signal or exception and the stack, then the process dies as it would have (the OS's own
// report still happens). The next launch says so in a toast and renames the file crash-<time>.txt, so a bug
// report has something to attach. It runs inside the crashing process, so a smashed heap can lose the
// report; the handler only calls async-signal-safe functions and allocates nothing. A stack overflow on the
// main thread still reports: the handler runs on its own stack (sigaltstack; on Windows, a stack guarantee).
crash_start :: () {
	dir := app_data_dir("logs");
	make_directory_if_it_does_not_exist(dir, recursive = true);
	path := tprint("%/crash.txt", dir);
	if file_exists(path) {
		file_move(path, tprint("%/crash-%.txt", dir, to_seconds(current_time_consensus() - dc.UNIX_EPOCH)));
		toast_show(L("fastcord quit unexpectedly last time. The report is in the logs folder (Settings, under Log Out)."), false);
	}
	crash_path = to_c_string(path); // heap, for the handler
	#if OS == .WINDOWS {
		SetUnhandledExceptionFilter(on_exception);
		guarantee: u32 = ALT_STACK;
		SetThreadStackGuarantee(*guarantee);
	} else {
		ss: posix.stack_t;
		ss.ss_sp = alloc(ALT_STACK);
		ss.ss_size = ALT_STACK;
		posix.sigaltstack(*ss, null);
		sa: posix.sigaction_t;
		sa.sa_handler = on_signal;
		sa.sa_flags = posix.SA_RESETHAND | posix.SA_ONSTACK; // runs once, then the default action kills the process
		for s32.[posix.SIGSEGV, posix.SIGBUS, posix.SIGILL, posix.SIGFPE, posix.SIGABRT] posix.sigaction(it, *sa, null);
	}
}

#scope_file

crash_path: *u8;
ALT_STACK :: 64 * 1024; // the handler's own stack: its buffers plus backtrace's

// Appends v to b at *n in the given base, without allocating.
put_num :: (b: []u8, n: *int, v: u64, base: u64 = 10) #no_context {
	digits: [20]u8;
	k := 0;
	while true {
		d := v % base;
		digits[k] = cast(u8) ifx d < 10 then #char "0" + d else #char "a" + d - 10;
		k += 1;
		v /= base;
		if !v break;
	}
	while k > 0 && n.* < b.count { k -= 1; b[n.*] = digits[k]; n.* += 1; }
}

put_str :: (b: []u8, n: *int, s: string) #no_context {
	c := ifx s.count < b.count - n.* then s.count else b.count - n.*;
	memcpy(b.data + n.*, s.data, c);
	n.* += c;
}

HEADER :: #run tprint("fastcord % crashed: ", FASTCORD_VERSION);

#if OS == .WINDOWS {
	on_exception :: (info: *EXCEPTION_POINTERS) -> s32 #c_call {
		h := CreateFileA(crash_path, 0x40000000 /*GENERIC_WRITE*/, 0, null, 2 /*CREATE_ALWAYS*/, 0, null);
		if h == cast(*void) -1 return 0;
		b: [4096]u8;
		n := 0;
		put_str(b, *n, HEADER);
		put_str(b, *n, "exception 0x");
		put_num(b, *n, info.record.code, 16);
		put_str(b, *n, " at 0x");
		put_num(b, *n, cast(u64) info.record.address, 16);
		// Addresses as offsets into the exe, which its PDB resolves.
		base := cast(u64) GetModuleHandleA(null);
		put_str(b, *n, "\nstack (exe offsets; others absolute):\n");
		frames: [62]*void;
		count := RtlCaptureStackBackTrace(0, 62, frames.data, null);
		for 0..cast(int) count - 1 {
			a := cast(u64) frames[it];
			put_str(b, *n, "  0x");
			put_num(b, *n, ifx a > base && a - base < 0x1000_0000 then a - base else a, 16);
			put_str(b, *n, "\n");
		}
		written: u32;
		WriteFile(h, b.data, xx n, *written, null);
		CloseHandle(h);
		return 0; // EXCEPTION_CONTINUE_SEARCH: Windows Error Reporting as before
	}

	EXCEPTION_POINTERS :: struct { record: *struct { code: u32; flags: u32; next: *void; address: *void; }; ctx: *void; }
	k32 :: #system_library "kernel32";
	SetThreadStackGuarantee :: (size: *u32) -> s32 #foreign k32;
	SetUnhandledExceptionFilter :: (filter: (info: *EXCEPTION_POINTERS) -> s32 #c_call) -> *void #foreign k32;
	CreateFileA :: (name: *u8, access: u32, share: u32, sec: *void, disposition: u32, flags: u32, template: *void) -> *void #foreign k32;
	WriteFile :: (h: *void, data: *void, count: u32, written: *u32, overlapped: *void) -> s32 #foreign k32;
	CloseHandle :: (h: *void) -> s32 #foreign k32;
	GetModuleHandleA :: (name: *u8) -> *void #foreign k32;
	RtlCaptureStackBackTrace :: (skip: u32, count: u32, frames: **void, hash: *u32) -> u16 #foreign k32;
} else {
	posix :: #import "POSIX";

	on_signal :: (sig: s32) #c_call {
		fd := creat(crash_path, 0x1a4 /*0644*/);
		if fd < 0 { raise(sig); return; }
		b: [256]u8;
		n := 0;
		put_str(b, *n, HEADER);
		put_str(b, *n, "signal ");
		put_num(b, *n, cast(u64) sig);
		put_str(b, *n, "\nstack:\n");
		posix.write(fd, b.data, xx n);
		frames: [64]*void;
		count := backtrace(frames.data, 64);
		backtrace_symbols_fd(frames.data, count, fd);
		posix.close(fd);
		raise(sig); // the default action now (SA_RESETHAND), also for a signal sent from outside
	}

	libc_c :: #system_library "libc";
	creat :: (path: *u8, mode: u32) -> s32 #foreign libc_c;
	raise :: (sig: s32) -> s32 #foreign libc_c;
	backtrace :: (frames: **void, size: s32) -> s32 #foreign libc_c;
	backtrace_symbols_fd :: (frames: **void, size: s32, fd: s32) #foreign libc_c;
}
