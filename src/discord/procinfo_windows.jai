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

// system_idle_ms: time since the last user input (GetLastInputInfo, as Chromium's idle time).
system_idle_ms :: () -> s64, bool {
	li := Last_Input_Info.{cbSize = size_of(Last_Input_Info)};
	if !last_input_info(*li) return 0, false;
	return cast(s64) (tick_count() - li.dwTime), true;
}

// windows_platform: the official Windows client (read from 1.0.9266: traffic/CLIENT_RULES.md). os_version is
// os.release() ("10.0.26100", RtlGetVersion: Windows 11 is 10.0 too), os_sdk_version its build. The app is
// x64; os_arch is arm64 when the bundle's PROCESSOR_* check says so. The strings live for the process.
windows_platform :: () -> Platform_Info {
	p := DEFAULT_PLATFORM;
	p.os_product_version = ""; // the updater sends os_version
	p.os = "Windows";
	v := Os_Version_Info.{size = size_of(Os_Version_Info)};
	if RtlGetVersion(*v) == 0 {
		p.os_version = sprint("%.%.%", v.major, v.minor, v.build);
		p.os_sdk_version = sprint("%", v.build);
	}
	env :: (name: *u8) -> string {
		buf: [256]u8;
		n := GetEnvironmentVariableA(name, buf.data, buf.count);
		return ifx n > 0 && n < buf.count then to_lower_copy(to_string(buf.data, n),, temp) else "";
	}
	arm := env("PROCESSOR_ARCHITECTURE") == "arm64" || env("PROCESSOR_ARCHITEW6432") == "arm64" || contains(env("PROCESSOR_IDENTIFIER"), "arm");
	p.os_arch = ifx arm then "arm64" else "x64";
	p.app_arch = "x64";
	p.ua_os_token = "Windows NT 10.0; Win64; x64";
	apply_host(*p, WINDOWS_HOST);
	p.sec_ch_ua_platform = "\"Windows\"";
	with_system(*p, ui_language(), windows_timezone());
	return p;
}

#scope_file

// ui_language: the first preferred UI language ("en-US"), as Chromium's locale on Windows.
ui_language :: () -> string {
	n, size: u32;
	buf: [256]u16;
	size = buf.count;
	if !GetUserPreferredUILanguages(MUI_LANGUAGE_NAME, *n, buf.data, *size) || n == 0 return "en-US";
	s, ok := wide_to_utf8(buf.data,, temp);
	return ifx ok && s then s else "en-US";
}

// windows_timezone: ICU's detection (wintz.cpp), which Chromium's Intl reports: the zone's key name mapped
// to an IANA id for the user's region by the system ICU (Windows 10 1903+). "" when unavailable.
windows_timezone :: () -> string {
	tzi: Dynamic_Time_Zone_Information;
	if GetDynamicTimeZoneInformation(*tzi) == 0xFFFF_FFFF return "";
	icu := LoadLibraryA("icu.dll");
	if !icu return "";
	map := cast(Ucal_Windows_Id) GetProcAddress(icu, "ucal_getTimeZoneIDForWindowsID");
	if !map return "";
	geo: [8]u16;
	region_c: [3]u8;
	if GetGeoInfoW(GetUserGeoID(GEOCLASS_NATION), GEO_ISO2, geo.data, geo.count, 0) == 3 {
		region_c[0], region_c[1] = cast(u8) geo[0], cast(u8) geo[1];
	}
	id: [128]u16;
	status: s32;
	n := map(tzi.key_name.data, -1, ifx region_c[0] then region_c.data else null, id.data, id.count - 1, *status);
	if status > 0 || n <= 0 return "";
	s, ok := wide_to_utf8(id.data, n);
	return ifx ok then s else "";
}

Ucal_Windows_Id :: #type (winid: *u16, len: s32, region: *u8, id: *u16, capacity: s32, status: *s32) -> s32 #c_call;

Os_Version_Info :: struct { size, major, minor, build, platform: u32; csd: [128]u16; }

Dynamic_Time_Zone_Information :: struct {
	bias: s32;
	standard_name: [32]u16;
	standard_date: [8]u16;
	standard_bias: s32;
	daylight_name: [32]u16;
	daylight_date: [8]u16;
	daylight_bias: s32;
	key_name: [128]u16;
	dynamic_daylight_time_disabled: u8;
}

MUI_LANGUAGE_NAME :: 0x8;
GEOCLASS_NATION :: 16;
GEO_ISO2 :: 4;
ntdll :: #system_library "ntdll";
GetEnvironmentVariableA :: (name: *u8, buf: *u8, size: u32) -> u32 #foreign kernel32;
RtlGetVersion :: (info: *Os_Version_Info) -> s32 #foreign ntdll;
GetUserPreferredUILanguages :: (flags: u32, count: *u32, buffer: *u16, size: *u32) -> BOOL #foreign kernel32;
GetDynamicTimeZoneInformation :: (info: *Dynamic_Time_Zone_Information) -> u32 #foreign kernel32;
GetUserGeoID :: (geo_class: u32) -> s32 #foreign kernel32;
GetGeoInfoW :: (location: s32, geo_type: u32, data: *u16, count: s32, lang: u16) -> s32 #foreign kernel32;

#import "Windows";
#import "Windows_Utf8";

kernel32 :: #system_library "kernel32";
user32 :: #system_library "user32";

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

Last_Input_Info :: struct { cbSize: u32; dwTime: u32; }
last_input_info :: (info: *Last_Input_Info) -> BOOL #foreign user32 "GetLastInputInfo";
tick_count :: () -> u32 #foreign kernel32 "GetTickCount";
K32GetProcessMemoryInfo :: (process: HANDLE, counters: *Process_Memory_Counters, cb: u32) -> BOOL #foreign kernel32;
GetProcessTimes :: (process: HANDLE, creation: *FILETIME, exit: *FILETIME, kernel: *FILETIME, user: *FILETIME) -> BOOL #foreign kernel32;
CreateToolhelp32Snapshot :: (flags: u32, pid: u32) -> HANDLE #foreign kernel32;
Process32FirstW :: (snapshot: HANDLE, entry: *Process_Entry32W) -> BOOL #foreign kernel32;
Process32NextW :: (snapshot: HANDLE, entry: *Process_Entry32W) -> BOOL #foreign kernel32;
