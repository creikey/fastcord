#+build windows
package discord

import win "core:sys/windows"
import "core:time"

@(private)
_process_resident_bytes :: proc() -> (i64, bool) {
	pmc: win.PROCESS_MEMORY_COUNTERS
	pmc.cb = size_of(pmc)
	if !win.GetProcessMemoryInfo(win.GetCurrentProcess(), &pmc, size_of(pmc)) do return 0, false
	return i64(pmc.WorkingSetSize), true
}

@(private)
_process_cpu_time :: proc() -> (time.Duration, bool) {
	c, e, k, u: win.FILETIME
	if !win.GetProcessTimes(win.GetCurrentProcess(), &c, &e, &k, &u) do return 0, false
	to100ns :: proc(f: win.FILETIME) -> i64 {return i64(f.dwHighDateTime) << 32 | i64(f.dwLowDateTime)}
	return time.Duration((to100ns(k) + to100ns(u)) * 100), true
}

// process_exe_paths: every running process's executable file name (Toolhelp gives no directory).
process_exe_paths :: proc(allocator := context.allocator) -> []string {
	out := make([dynamic]string, 0, 256, allocator)
	snap := win.CreateToolhelp32Snapshot(win.TH32CS_SNAPPROCESS, 0)
	if snap == win.INVALID_HANDLE_VALUE do return out[:]
	defer win.CloseHandle(snap)
	pe := win.PROCESSENTRY32W{dwSize = size_of(win.PROCESSENTRY32W)}
	for ok := win.Process32FirstW(snap, &pe); ok; ok = win.Process32NextW(snap, &pe) {
		if s, err := win.wstring_to_utf8(cstring16(&pe.szExeFile[0]), -1, allocator); err == nil do append(&out, s)
	}
	return out[:]
}
