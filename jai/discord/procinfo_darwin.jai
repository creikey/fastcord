#scope_module

Mach_Task_Basic_Info :: struct {
	virtual_size: u64;
	resident_size: u64;
	resident_size_max: u64;
	user_time: [2]s32;
	system_time: [2]s32;
	policy: s32;
	suspend_count: s32;
}
#scope_export

MACH_TASK_BASIC_INFO :: 20;
#scope_module

_process_resident_bytes :: () -> s64, bool {
	info: Mach_Task_Basic_Info;
	count := cast(u32)(size_of(Mach_Task_Basic_Info) / 4);
	kr := darwin.task_info(darwin.mach_task_self(), MACH_TASK_BASIC_INFO, darwin.task_info_t(cast(*void)(*info)), *count);
	if kr != .Success { return 0, false; }
	return cast(s64)(info.resident_size), true;
}

_process_cpu_time :: () -> time.Duration, bool {
	ru: posix.rusage;
	if posix.getrusage(.SELF, *ru) != .OK { return 0, false; }
	us := cast(s64)(ru.ru_utime.tv_sec) * 1_000_000 + cast(s64)(ru.ru_utime.tv_usec) + cast(s64)(ru.ru_stime.tv_sec) * 1_000_000 + cast(s64)(ru.ru_stime.tv_usec);
	return time.Duration(us) * time.Microsecond, true;
}
#scope_export

// process_exe_paths: every running process's executable path (unreadable ones are skipped).
process_exe_paths :: (allocator := context.allocator) -> []string {
	pids: [4096]s32;
	n := cast(int)(darwin.proc_listallpids(*pids[0], size_of(pids))); // returns a count, not bytes
	out := make_dynamic(string, 0, max(n, 0), allocator);
	for pid: sub(pids, 0, clamp(n, 0, len(pids))) {
		buf: [darwin.PIDPATHINFO_MAXSIZE]u8;
		l := darwin.proc_pidpath(posix.pid_t(pid), *buf[0], len(buf));
		if l > 0 { append(*out, clone(as_string(sub(buf, 0, l)), allocator)); }
	}
	return view(out);
}

