write_thread_stacks :: (b: *String_Builder, main_tid: int) {
	using Windows;
	me := GetCurrentThreadId();
	pid := GetCurrentProcessId();
	snap := CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
	if snap == INVALID_HANDLE_VALUE return;
	defer CloseHandle(snap);
	process := GetCurrentProcess();
	if !dbghelp_inited {
		dbghelp_inited = true;
		SymSetOptions(.LOAD_LINES | .DEFERRED_LOADS);
		SymInitialize(process, null, 1); // fails harmlessly when the profiler initialised it first
	}
	te := THREADENTRY32.{dwSize = size_of(THREADENTRY32)};
	ok := Thread32First(snap, *te);
	while ok {
		defer ok = Thread32Next(snap, *te);
		if te.th32OwnerProcessID != pid || te.th32ThreadID == me continue;
		// Symbol lookup allocates and takes DbgHelp locks, so it runs after the thread resumes.
		raw: [MAX_FRAMES]u64;
		n := prof.capture_thread(te.th32ThreadID, raw);
		print_to_builder(b, "\nthread %%\n", te.th32ThreadID, ifx cast(int) te.th32ThreadID == main_tid then " (main)" else "");
		for addr: array_view(raw, 0, n) {
			data: [size_of(SYMBOL_INFO) + 256]u8 #align 8;
			si := cast(*SYMBOL_INFO) data.data;
			si.SizeOfStruct = size_of(SYMBOL_INFO);
			si.MaxNameLen = 255;
			disp: u64;
			if !SymFromAddr(process, addr, *disp, si) {
				print_to_builder(b, "  0x%\n", formatInt(addr, base = 16));
				continue;
			}
			line := IMAGEHLP_LINE64.{SizeOfStruct = size_of(IMAGEHLP_LINE64)};
			ldisp: u32;
			file := "";
			if SymGetLineFromAddr64(process, addr, *ldisp, *line) file = to_string(line.FileName);
			print_to_builder(b, "  %  %:%\n", string.{si.NameLen, si.Name.data}, file, line.LineNumber);
		}
	}
}

#scope_file

MAX_FRAMES :: 48;
dbghelp_inited: bool;

TH32CS_SNAPTHREAD :: 0x4;
THREADENTRY32 :: struct {
	dwSize: u32;
	cntUsage: u32;
	th32ThreadID: u32;
	th32OwnerProcessID: u32;
	tpBasePri: s32;
	tpDeltaPri: s32;
	dwFlags: u32;
}
CreateToolhelp32Snapshot :: (flags: u32, pid: u32) -> Windows.HANDLE #foreign kernel32;
Thread32First :: (snap: Windows.HANDLE, te: *THREADENTRY32) -> Windows.BOOL #foreign kernel32;
Thread32Next :: (snap: Windows.HANDLE, te: *THREADENTRY32) -> Windows.BOOL #foreign kernel32;
