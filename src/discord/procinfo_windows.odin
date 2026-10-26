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
