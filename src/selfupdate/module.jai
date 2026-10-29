// Installs a fastcord release over the running copy; src/app/update.jai drives it from a worker thread, in
// release builds only. Nothing from the download runs before it is checked: the archive's SHA-256 must be
// the one in a manifest signed with the release key pinned here (Ed25519; release.yml signs with the
// FASTCORD_UPDATE_KEY secret), so a stolen GitHub token alone can't ship an update. The OS's own archiver
// unpacks it (ditto, bsdtar, tar), and the swap is two renames.
#import "Basic";
#import "File";
#import "File_Utilities";
#import "String";
#import "Process";
#import "System";
crypto :: #import "crypto";
#if OS == .WINDOWS {
	GetCurrentProcessId :: () -> u32 #foreign kernel32;
	kernel32 :: #system_library "kernel32";
} else {
	posix :: #import "POSIX";
}

MANIFEST :: "fastcord-update.txt";
SIGNATURE :: "fastcord-update.sig";
ASSET :: #run ifx OS == .MACOS then "fastcord-macos.zip" else ifx OS == .WINDOWS then "fastcord-windows.zip" else "fastcord-linux-x86_64.tar.gz";
PUBLIC_KEY :: "4be22ccd8a4cf8e5062dc5c7672c2f2888e2740fda074da40ce402012edebc79";
MAX_MANIFEST :: 4096;
MAX_ARCHIVE :: 256 << 20;

// The manifest is "fastcord-update <tag>" then one "<sha256 hex>  <asset>" line per archive (sha256sum's
// format). Returns asset's hash when sig is key's signature of the manifest and it names tag.
manifest_hash :: (manifest: string, sig: []u8, tag: string, asset := ASSET, key := PUBLIC_KEY) -> [32]u8, bool {
	out: [32]u8;
	if manifest.count > MAX_MANIFEST || !crypto.ed25519_verify(hex(key), xx manifest, sig) return out, false;
	lines := split(manifest, "\n",, temp);
	if lines[0] != join("fastcord-update ", tag,, temp) return out, false;
	for lines {
		if it.count != 66 + asset.count || slice(it, 64, 2) != "  " || advance(it, 66) != asset continue;
		h := hex(slice(it, 0, 64));
		if h.count != 32 return out, false;
		memcpy(out.data, h.data, 32);
		return out, true;
	}
	return out, false;
}

// Puts the app in archive (checked against manifest_hash) in place of target: the .app bundle on macOS,
// Fastcord.exe on Windows, the fastcord binary on Linux. The running copy becomes <target>.old, which
// restart's new process deletes (Windows can't delete a running exe). On failure target stays as it was.
install :: (archive: []u8, target: string) -> bool {
	staging := tprint("%.update", target);
	delete_path(staging);
	delete_path(old_path(target));
	if !make_directory_if_it_does_not_exist(staging) return false;
	defer delete_path(staging);
	file := tprint("%/%", staging, ASSET);
	if !write_entire_file(file, archive.data, archive.count) return false;
	#if OS == .MACOS {
		r := run_command("/usr/bin/ditto", "-x", "-k", file, staging);
		new := tprint("%/Fastcord.app", staging);
	} else #if OS == .WINDOWS {
		r := run_command("C:\\Windows\\System32\\tar.exe", "-xf", file, "-C", staging);
		new := tprint("%/Fastcord.exe", staging);
	} else {
		r := run_command("tar", "-xzf", file, "-C", staging);
		new := tprint("%/fastcord/fastcord", staging);
	}
	if r.exit_code != 0 || !file_exists(new) return false;
	if !file_move(target, old_path(target)) return false;
	if file_move(new, target) return true;
	file_move(old_path(target), target);
	return false;
}

// What install replaces for the running executable (exe), or "" when it can't: a Mac app run from its disk
// image or translocated. The caller rules out dev builds and, on Windows, an exe outside its install.
target_of :: (exe: string) -> string {
	#if OS == .MACOS {
		app := slice(exe, 0, max(find_index_from_right(exe, "/Contents/MacOS/"), 0));
		if !ends_with(app, ".app") || contains(app, "/AppTranslocation/") || begins_with(app, "/Volumes/") return "";
		return app;
	}
	return exe;
}

old_path :: (target: string) -> string { return tprint("%.old", target); }

// Starts the new copy at target with --replace:<pid>:<old>, then the caller quits; finish runs in it.
restart :: (target: string) -> bool {
	#if OS == .WINDOWS pid := GetCurrentProcessId(); else pid := posix.getpid();
	arg := tprint("--replace:%:%", pid, old_path(target));
	p: Process;
	#if OS == .MACOS return create_process(*p, "/usr/bin/open", "-n", target, "--args", arg, kill_process_if_parent_exits = false);
	else return create_process(*p, target, arg, kill_process_if_parent_exits = false);
}

#if OS != .WINDOWS {
	// The new copy's first launch: waits up to 10 s for the old process to end, then deletes its copy.
	finish :: (pid: s32, old: string) {
		for 1..100 { if posix.kill(pid, 0) != 0 break; sleep_milliseconds(100); }
		if ends_with(old, ".old") delete_path(old);
	}
}

// Deletes a file or a directory tree.
delete_path :: (path: string) {
	if file_exists(path) && !file_delete(path) delete_directory(path);
}

#scope_file

// Lower- or upper-case hex to bytes; empty on anything else.
hex :: (s: string) -> []u8 {
	if s.count % 2 return .[];
	out := NewArray(s.count / 2, u8,, temp);
	for 0..out.count - 1 {
		hi, lo := nibble(s[2 * it]), nibble(s[2 * it + 1]);
		if hi < 0 || lo < 0 return .[];
		out[it] = cast(u8) (hi * 16 + lo);
	}
	return out;
}

nibble :: (c: u8) -> int {
	if c >= #char "0" && c <= #char "9" return c - #char "0";
	if c >= #char "a" && c <= #char "f" return c - #char "a" + 10;
	if c >= #char "A" && c <= #char "F" return c - #char "A" + 10;
	return -1;
}
