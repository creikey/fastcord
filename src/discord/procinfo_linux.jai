// /proc/self/statm's resident pages, the process CPU clock, and /proc/<pid>/exe of every visible process.
process_resident_bytes :: () -> s64, bool {
	s, ok := read_entire_file("/proc/self/statm", log_errors = false); // "size resident shared text lib data dt" in pages
	if !ok return 0, false;
	defer free(s);
	fields := split(s, " ",, temp);
	if fields.count < 2 return 0, false;
	pages, parsed := string_to_int(fields[1]);
	if !parsed return 0, false;
	return pages * sysconf(._SC_PAGESIZE), true;
}

process_cpu_ns :: () -> s64, bool {
	ts: timespec;
	if clock_gettime(.CLOCK_PROCESS_CPUTIME_ID, *ts) != 0 return 0, false;
	return ts.tv_sec * 1_000_000_000 + ts.tv_nsec, true;
}

// process_exe_paths: every running process's executable path (other users' processes are unreadable and skipped).
process_exe_paths :: () -> []string {
	out: [..]string;
	dir := opendir("/proc");
	if !dir return out;
	defer closedir(dir);
	while true {
		e := readdir(dir);
		if !e break;
		name := to_string(e.d_name.data);
		if !name || name[0] < #char "0" || name[0] > #char "9" continue; // pids only
		buf: [4096]u8;
		l := readlink(temp_c_string(tprint("/proc/%/exe", name)), buf.data, buf.count);
		if l > 0 array_add(*out, copy_string(to_string(buf.data, l)));
	}
	return out;
}

// linux_platform: the official Linux desktop client's super properties (no capture yet: see
// traffic/CLIENT_RULES.md). The Linux app has its own version line; Electron is read from its package. The
// strings live for the process.
linux_platform :: () -> Platform_Info {
	p := DEFAULT_PLATFORM;
	p.os_product_version = ""; // the updater sends os_version
	p.os = "Linux";
	u: utsname;
	if uname(*u) == 0 p.os_version = copy_string(to_string(u.release.data));
	p.os_arch, p.app_arch = "x64", "x64";
	p.ua_os_token = "X11; Linux x86_64";
	apply_host(*p, LINUX_HOST);
	p.os_sdk_version = "";
	p.sec_ch_ua_platform = "\"Linux\"";
	env :: (name: *u8, default: string) -> string { v := to_string(c_getenv(name)); return ifx v then copy_string(v) else default; }
	// Chromium's locale on Linux: the first of $LANGUAGE, else $LC_ALL / $LC_MESSAGES / $LANG ("C" = en-US)
	lang := env("LANGUAGE", "");
	colon := find_index_from_left(lang, #char ":");
	if colon >= 0 lang = slice(lang, 0, colon);
	for string.["LC_ALL", "LC_MESSAGES", "LANG"] if !lang lang = env(temp_c_string(it), "");
	if lang == "C" || lang == "POSIX" || begins_with(lang, "C.") lang = "en-US";
	with_system(*p, ifx lang then lang else "en-US", posix_timezone());
	p.window_manager = sprint("%,%", env("XDG_CURRENT_DESKTOP", "unknown"), env("GDMSESSION", "unknown"));
	p.distro = os_release_name();
	p.runtime_environment = "native";
	p.display_server = env("XDG_SESSION_TYPE", "unknown");
	return p;
}

// system_idle_ms: not measured on Linux (X has it only through the XScreenSaver extension, Wayland not at
// all), so presence never goes idle on its own there.
system_idle_ms :: () -> s64, bool { return 0, false; }

#scope_file

// os_release_name: PRETTY_NAME from os-release, unquoted.
os_release_name :: () -> string {
	for path: string.["/etc/os-release", "/usr/lib/os-release"] {
		s, ok := read_entire_file(path, log_errors = false,, temp);
		if !ok continue;
		for line: split(s, "\n",, temp) {
			if !begins_with(line, "PRETTY_NAME=") continue;
			v := trim(slice(line, 12, line.count - 12));
			if v.count >= 2 && (v[0] == #char "\"" || v[0] == #char "'") v = slice(v, 1, v.count - 2);
			return copy_string(v);
		}
	}
	return "Linux";
}

#import "POSIX";
libc :: #system_library "libc";
c_getenv :: (name: *u8) -> *u8 #foreign libc "getenv"; // not getenv: tests declare one at module scope
#import "File";
#import "String";
