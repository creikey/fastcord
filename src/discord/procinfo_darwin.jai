process_resident_bytes :: () -> s64, bool {
	info: Mach_Task_Basic_Info;
	count := cast(u32) (size_of(Mach_Task_Basic_Info) / 4);
	if task_info(mach_task_self_, MACH_TASK_BASIC_INFO, *info, *count) != 0 return 0, false;
	return cast(s64) info.resident_size, true;
}

process_cpu_ns :: () -> s64, bool {
	ru: Rusage;
	if getrusage(0, *ru) != 0 return 0, false; // RUSAGE_SELF
	us := (ru.utime.sec + ru.stime.sec) * 1_000_000 + ru.utime.usec + ru.stime.usec;
	return us * 1000, true;
}

// process_exe_paths: every running process's executable path (unreadable ones are skipped).
process_exe_paths :: () -> []string {
	pids: [4096]s32;
	n := clamp(proc_listallpids(pids.data, size_of(type_of(pids))), 0, pids.count); // a count, not bytes
	out: [..]string;
	array_reserve(*out, n);
	for pid: array_view(pids, 0, n) {
		buf: [PIDPATHINFO_MAXSIZE]u8;
		l := proc_pidpath(pid, buf.data, buf.count);
		if l > 0 array_add(*out, copy_string(to_string(buf.data, l)));
	}
	return out;
}

// system_idle_ms: time since the last user input anywhere (Electron's powerMonitor.getSystemIdleTime).
system_idle_ms :: () -> s64, bool {
	s := CGEventSourceSecondsSinceLastEventType(0, 0xFFFF_FFFF); // combined session state, any input
	return cast(s64) (s * 1000), s >= 0;
}

#scope_file

libc :: #system_library "libc";
core_graphics :: #library,system,link_always "CoreGraphics";
CGEventSourceSecondsSinceLastEventType :: (state: s32, event_type: u32) -> float64 #foreign core_graphics;

MACH_TASK_BASIC_INFO :: 20;
PIDPATHINFO_MAXSIZE :: 4096;

Mach_Task_Basic_Info :: struct {
	virtual_size: u64;
	resident_size: u64;
	resident_size_max: u64;
	user_time: [2]s32;
	system_time: [2]s32;
	policy: s32;
	suspend_count: s32;
}

Timeval :: struct { sec: s64; usec: s32; }
Rusage :: struct { utime: Timeval; stime: Timeval; rest: [14]s64; }

mach_task_self_: u32 #elsewhere libc;
task_info :: (task: u32, flavor: s32, info: *void, count: *u32) -> s32 #foreign libc;
getrusage :: (who: s32, usage: *Rusage) -> s32 #foreign libc;
proc_listallpids :: (buf: *s32, size: s32) -> s32 #foreign libc;
proc_pidpath :: (pid: s32, buf: *u8, size: u32) -> s32 #foreign libc;
