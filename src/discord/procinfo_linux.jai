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

// linux_platform: the official Linux desktop client's super properties, as read from 1.0.167 in WSL over CDP
// (traffic/CLIENT_RULES.md). The strings live for the process.
linux_platform :: () -> Platform_Info {
	p := DEFAULT_PLATFORM;
	p.os = "Linux";
	u: utsname;
	if uname(*u) == 0 p.os_version = copy_string(to_string(u.release.data));
	p.os_product_version = os_release_field("VERSION_ID", ""); // the updater's platform_version ("24.04")
	p.os_arch, p.app_arch = "x64", "x64";
	p.ua_os_token = "X11; Linux x86_64";
	apply_host(*p, LINUX_HOST);
	p.os_sdk_version = "";
	p.sec_ch_ua_platform = "\"Linux\"";
	// Chromium's locale on Linux: the first of $LANGUAGE, else $LC_ALL / $LC_MESSAGES / $LANG ("C" = en-US)
	lang := env("LANGUAGE", "");
	colon := find_index_from_left(lang, #char ":");
	if colon >= 0 lang = slice(lang, 0, colon);
	for string.["LC_ALL", "LC_MESSAGES", "LANG"] if !lang lang = env(temp_c_string(it), "");
	if lang == "C" || lang == "POSIX" || begins_with(lang, "C.") lang = "en-US";
	with_system(*p, .[ifx lang then lang else "en-US"], posix_timezone());
	p.accept_language = linux_accept_language(p.system_locale, env("LANGUAGE", ""), env("LC_ALL", ""), env("LC_MESSAGES", ""), env("LANG", ""));
	p.window_manager = sprint("%,%", env("XDG_CURRENT_DESKTOP", "unknown"), env("GDMSESSION", "unknown"));
	p.distro = os_release_field("PRETTY_NAME", "Linux");
	p.runtime_environment = "native";
	p.display_server = env("XDG_SESSION_TYPE", "unknown");
	return p;
}

// system_idle_ms: time since the last user input, from the XScreenSaver extension, as Chromium's X11
// idle query does (on Wayland desktops, through XWayland: input to Wayland windows may not count). Each
// client's gateway thread polls it every 10 s, so each call opens its own display connection.
system_idle_ms :: () -> s64, bool {
	if compare_and_swap(*xss.state, 0, 1) {
		x11 := dlopen("libX11.so.6", RTLD_NOW);
		ext := dlopen("libXss.so.1", RTLD_NOW);
		if x11 && ext {
			xss.open = xx dlsym(x11, "XOpenDisplay");
			xss.close = xx dlsym(x11, "XCloseDisplay");
			xss.root = xx dlsym(x11, "XDefaultRootWindow");
			xss.query = xx dlsym(ext, "XScreenSaverQueryInfo");
		}
		atomic_store(*xss.state, cast(s32) ifx xss.open && xss.close && xss.root && xss.query then 2 else 3);
	}
	if atomic_load(*xss.state) != 2 return 0, false;
	d := xss.open(null);
	if !d return 0, false;
	defer xss.close(d);
	info: struct { window: u64; state, kind: s32; til_or_since, idle, event_mask: u64; }; // XScreenSaverInfo
	if xss.query(d, xss.root(d), *info) == 0 return 0, false;
	return cast(s64) info.idle, true;
}

#scope_file

// os_release_field: a key of os-release, unquoted (default when absent).
os_release_field :: (key: string, default: string) -> string {
	for path: string.["/etc/os-release", "/usr/lib/os-release"] {
		s, ok := read_entire_file(path, log_errors = false,, temp);
		if !ok continue;
		for line: split(s, "\n",, temp) {
			if !begins_with(line, key) || line.count <= key.count || line[key.count] != #char "=" continue;
			v := trim(slice(line, key.count + 1, line.count - key.count - 1));
			if v.count >= 2 && (v[0] == #char "\"" || v[0] == #char "'") v = slice(v, 1, v.count - 2);
			return copy_string(v);
		}
	}
	return default;
}

env :: (name: *u8, default: string) -> string { v := to_string(c_getenv(name)); return ifx v then copy_string(v) else default; }

xss: struct {
	state: s32; // 0 not tried, 1 loading, 2 loaded, 3 missing
	open: (name: *u8) -> *void #c_call;
	close: (d: *void) -> s32 #c_call;
	root: (d: *void) -> u64 #c_call;
	query: (d: *void, drawable: u64, info: *void) -> s32 #c_call;
};

#import "POSIX";
#import "Atomics";
libc :: #system_library "libc";
c_getenv :: (name: *u8) -> *u8 #foreign libc "getenv"; // not getenv: tests declare one at module scope
#import "File";
#import "String";
