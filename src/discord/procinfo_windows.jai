process_resident_bytes :: () -> s64, bool {
	pmc: Process_Memory_Counters;
	pmc.cb = size_of(Process_Memory_Counters);
	if !K32GetProcessMemoryInfo(GetCurrentProcess(), *pmc, size_of(Process_Memory_Counters)) return 0, false;
	return cast(s64) pmc.WorkingSetSize, true;
}

process_cpu_ns :: () -> s64, bool {
	c, e, k, u: FILETIME;
	if !GetProcessTimes(GetCurrentProcess(), *c, *e, *k, *u) return 0, false;
	to100ns :: (f: FILETIME) -> s64 { return ((cast(s64) f.dwHighDateTime) << 32) | (cast(s64) f.dwLowDateTime); }
	return (to100ns(k) + to100ns(u)) * 100, true;
}

// process_exe_paths: every running process's executable file name (Toolhelp gives no directory).
process_exe_paths :: () -> []string {
	out: [..]string;
	snap := CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
	if snap == INVALID_HANDLE_VALUE return out;
	defer CloseHandle(snap);
	pe := Process_Entry32W.{dwSize = size_of(Process_Entry32W)};
	ok := Process32FirstW(snap, *pe);
	while ok {
		s, converted := wide_to_utf8(pe.szExeFile.data);
		if converted array_add(*out, s);
		ok = Process32NextW(snap, *pe);
	}
	return out;
}

#scope_file

#import "Windows";
#import "Windows_Utf8";

kernel32 :: #system_library "kernel32";

TH32CS_SNAPPROCESS :: 0x2;

Process_Memory_Counters :: struct {
	cb: u32;
	PageFaultCount: u32;
	PeakWorkingSetSize: u64;
	WorkingSetSize: u64;
	QuotaPeakPagedPoolUsage: u64;
	QuotaPagedPoolUsage: u64;
	QuotaPeakNonPagedPoolUsage: u64;
	QuotaNonPagedPoolUsage: u64;
	PagefileUsage: u64;
	PeakPagefileUsage: u64;
}

Process_Entry32W :: struct {
	dwSize: u32;
	cntUsage: u32;
	th32ProcessID: u32;
	th32DefaultHeapID: u64;
	th32ModuleID: u32;
	cntThreads: u32;
	th32ParentProcessID: u32;
	pcPriClassBase: s32;
	dwFlags: u32;
	szExeFile: [260]u16;
}

K32GetProcessMemoryInfo :: (process: HANDLE, counters: *Process_Memory_Counters, cb: u32) -> BOOL #foreign kernel32;
GetProcessTimes :: (process: HANDLE, creation: *FILETIME, exit: *FILETIME, kernel: *FILETIME, user: *FILETIME) -> BOOL #foreign kernel32;
CreateToolhelp32Snapshot :: (flags: u32, pid: u32) -> HANDLE #foreign kernel32;
Process32FirstW :: (snapshot: HANDLE, entry: *Process_Entry32W) -> BOOL #foreign kernel32;
Process32NextW :: (snapshot: HANDLE, entry: *Process_Entry32W) -> BOOL #foreign kernel32;
