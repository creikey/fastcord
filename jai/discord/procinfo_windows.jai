#scope_module

_process_resident_bytes :: () -> s64, bool {
	pmc: win.PROCESS_MEMORY_COUNTERS;
	pmc.cb = size_of(type_of(pmc));
	if !win.GetProcessMemoryInfo(win.GetCurrentProcess(), *pmc, size_of(type_of(pmc))) { return 0, false; }
	return cast(s64)(pmc.WorkingSetSize), true;
}

_process_cpu_time :: () -> time.Duration, bool {
	c, e, k, u: win.FILETIME;
	if !win.GetProcessTimes(win.GetCurrentProcess(), *c, *e, *k, *u) { return 0, false; }
	to100ns :: (f: win.FILETIME) -> s64 {return ((cast(s64)(f.dwHighDateTime)) << 32) | (cast(s64)(f.dwLowDateTime));}
	return cast(time.Duration)((to100ns(k) + to100ns(u)) * 100), true;
}
#scope_export

// process_exe_paths: every running process's executable file name (Toolhelp gives no directory).
process_exe_paths :: (allocator := context.allocator) -> []string {
	out := make_dynamic(string, 0, 256, allocator);
	snap := win.CreateToolhelp32Snapshot(win.TH32CS_SNAPPROCESS, 0);
	if snap == win.INVALID_HANDLE_VALUE { return view(out); }
	defer win.CloseHandle(snap);
	pe := win.PROCESSENTRY32W.{dwSize = size_of(win.PROCESSENTRY32W)};
	{ ok := win.Process32FirstW(snap, *pe);
	while ok {
		{ s, err := win.wstring_to_utf8(cstring16(*pe.szExeFile[0]), -1, allocator);
		if err == null { append(*out, s); } }
		ok = win.Process32NextW(snap, *pe);
} }
	return view(out);
}

