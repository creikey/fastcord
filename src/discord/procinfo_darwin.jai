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

// darwin_platform: os_version is os.release() (the Darwin kernel release), os_sdk_version its major.
// The official app is universal, so os.arch() is the machine's: arm64 on Apple silicon even when fastcord
// itself runs under Rosetta. The user agent stays Chrome's frozen "Intel Mac OS X 10_15_7".
darwin_platform :: () -> Platform_Info {
	p := DEFAULT_PLATFORM;
	u: Utsname;
	if uname(*u) == 0 {
		p.os_version = copy_string(to_string(u.release.data));
		dot := find_index_from_left(p.os_version, #char ".");
		p.os_sdk_version = ifx dot > 0 then slice(p.os_version, 0, dot) else p.os_version;
	}
	product: [32]u8;
	psize: u64 = product.count;
	if sysctlbyname("kern.osproductversion", product.data, *psize, null, 0) == 0 && psize > 1 && psize <= product.count
		p.os_product_version = copy_string(to_string(product.data, xx psize - 1));
	arm: s32;
	size: u64 = size_of(s32);
	arm64 := sysctlbyname("hw.optional.arm64", *arm, *size, null, 0) == 0 && arm == 1;
	p.os_arch = ifx arm64 then "arm64" else "x64";
	p.app_arch = p.os_arch;
	with_system(*p, preferred_language(), posix_timezone());
	return p;
}

#scope_file

// preferred_language: the first of the user's preferred languages ("en-US", "zh-Hans-CN").
preferred_language :: () -> string {
	langs := CFLocaleCopyPreferredLanguages();
	if !langs return "en-US";
	defer CFRelease(langs);
	buf: [64]u8;
	if CFArrayGetCount(langs) < 1 || !CFStringGetCString(CFArrayGetValueAtIndex(langs, 0), buf.data, buf.count, 0x0800_0100) return "en-US"; // UTF-8
	return copy_string(to_string(buf.data),, temp);
}

libc :: #system_library "libc";
core_graphics :: #library,system,link_always "CoreGraphics";
core_foundation :: #library,system,link_always "CoreFoundation";
CGEventSourceSecondsSinceLastEventType :: (state: s32, event_type: u32) -> float64 #foreign core_graphics;
CFLocaleCopyPreferredLanguages :: () -> *void #foreign core_foundation;
CFArrayGetCount :: (array: *void) -> s64 #foreign core_foundation;
CFArrayGetValueAtIndex :: (array: *void, index: s64) -> *void #foreign core_foundation;
CFStringGetCString :: (s: *void, buf: *u8, size: s64, encoding: u32) -> bool #foreign core_foundation;
CFRelease :: (object: *void) #foreign core_foundation;

Utsname :: struct { sysname, nodename, release, version, machine: [256]u8; }
uname :: (u: *Utsname) -> s32 #foreign libc;
sysctlbyname :: (name: *u8, old: *void, old_size: *u64, new: *void, new_size: u64) -> s32 #foreign libc;

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
