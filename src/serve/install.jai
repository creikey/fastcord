// `fastcord -serve:<file> -install` / `-uninstall`: run the server as a per-user service that starts at login
// (macOS: a launchd agent; Linux: a systemd user unit; Windows: a scheduled task at logon) and restarts when
// it fails. A service has no console, so it runs with -service and writes only to <file>.log.

#import "Process";
#import "System";

// install_service registers (or with uninstall, removes) the service for the server file; the message says
// what happened or why not.
install_service :: (file: string, port: int, uninstall: bool) -> bool, string {
	path, got := get_absolute_path(file);
	if !got return false, tprint("can't find %", file);
	exe := get_path_of_running_executable();
	name := service_name(path);
	#if OS == .MACOS {
		label := tprint("com.fastcord.serve.%", name);
		home := to_string(getenv("HOME"));
		plist := tprint("%/Library/LaunchAgents/%.plist", home, label);
		domain := tprint("gui/%", getuid());
		run_command("launchctl", "bootout", tprint("%/%", domain, label));
		if uninstall {
			file_delete(plist);
			return true, tprint("Removed the service %. The server file and its backups stay.", label);
		}
		make_directory_if_it_does_not_exist(tprint("%/Library/LaunchAgents", home), recursive = true);
		text := tprint(LAUNCHD, xml(label), xml(exe), xml(tprint("-serve:%", path)), port);
		if !write_entire_file(plist, text) return false, tprint("can't write %", plist);
		if run_command("launchctl", "bootstrap", domain, plist).exit_code != 0 return false, tprint("launchctl couldn't load %", plist);
		return true, tprint("Installed % (%): it starts at login and restarts if it stops. Its log: %.log", label, plist, path);
	} else #if OS == .LINUX {
		unit := tprint("fastcord-%.service", name);
		config := to_string(getenv("XDG_CONFIG_HOME"));
		if !config config = tprint("%/.config", to_string(getenv("HOME")));
		dir := tprint("%/systemd/user", config);
		if uninstall {
			run_command("systemctl", "--user", "disable", "--now", unit);
			file_delete(tprint("%/%", dir, unit));
			run_command("systemctl", "--user", "daemon-reload");
			return true, tprint("Removed the service %. The server file and its backups stay.", unit);
		}
		make_directory_if_it_does_not_exist(dir, recursive = true);
		text := tprint(SYSTEMD, name, unit_arg(exe), unit_arg(tprint("-serve:%", path)), port);
		if !write_entire_file(tprint("%/%", dir, unit), text) return false, tprint("can't write %/%", dir, unit);
		if run_command("systemctl", "--user", "daemon-reload").exit_code != 0 || run_command("systemctl", "--user", "enable", "--now", unit).exit_code != 0 {
			return false, tprint("systemctl couldn't start % (is there a systemd user session?)", unit);
		}
		return true, tprint("Installed %: it starts at login and restarts if it stops. Its log: %.log. To keep it running while you're logged out: loginctl enable-linger", unit, path);
	} else #if OS == .WINDOWS {
		task := tprint("Fastcord %", name);
		if uninstall {
			run_command("schtasks", "/End", "/TN", task);
			if run_command("schtasks", "/Delete", "/TN", task, "/F").exit_code != 0 return false, tprint("schtasks couldn't remove the task %", task);
			return true, tprint("Removed the task %. The server file and its backups stay.", task);
		}
		xml_path := tprint("%.task.xml", path);
		text := tprint(TASK, xml(exe), xml(tprint("\"-serve:%\" -port:% -service", path, port)));
		// schtasks reads the task as UTF-16 with its byte-order mark.
		wide := utf8_to_wide(text,, temp);
		n := 0;
		while wide[n] n += 1;
		bytes := NewArray(2 + 2 * n, u8,, temp);
		bytes[0], bytes[1] = 0xFF, 0xFE;
		memcpy(bytes.data + 2, wide, 2 * n);
		if !write_entire_file(xml_path, bytes.data, bytes.count) return false, tprint("can't write %", xml_path);
		defer file_delete(xml_path);
		if run_command("schtasks", "/Create", "/TN", task, "/XML", xml_path, "/F").exit_code != 0 return false, tprint("schtasks couldn't create the task %", task);
		run_command("schtasks", "/Run", "/TN", task);
		return true, tprint("Installed the task %: it starts at logon and restarts if it stops. Its log: %.log", task, path);
	} else {
		return false, "services aren't supported on this OS";
	}
}

#scope_module

// service_name is the file's name with only [A-Za-z0-9_-]: a launchd label, a unit or a task name.
service_name :: (path: string) -> string {
	n := copy_string(path_strip_extension(path_filename(path)),, temp);
	for i: 0..n.count - 1 if !is_alnum(n[i]) && n[i] != #char "-" n[i] = #char "_";
	return ifx n then n else "server";
}

xml :: (s: string) -> string {
	out := replace(s, "&", "&amp;",, temp);
	out = replace(out, "<", "&lt;",, temp);
	out = replace(out, ">", "&gt;",, temp);
	return replace(out, "\"", "&quot;",, temp);
}

// unit_arg quotes one ExecStart word for systemd: backslashes and quotes escaped, % doubled.
unit_arg :: (s: string) -> string {
	out := replace(s, "\\", "\\\\",, temp);
	out = replace(out, "\"", "\\\"",, temp);
	return tprint("\"%\"", replace(out, "%", "%%",, temp));
}

LAUNCHD :: #string XML
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>%1</string>
	<key>ProgramArguments</key>
	<array><string>%2</string><string>%3</string><string>-port:%4</string><string>-service</string></array>
	<key>RunAtLoad</key><true/>
	<key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
	<key>ThrottleInterval</key><integer>5</integer>
</dict>
</plist>
XML

SYSTEMD :: #string UNIT
[Unit]
Description=Fastcord server %1
After=network-online.target

[Service]
ExecStart=%2 %3 -port:%4 -service
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
UNIT

TASK :: #string XML
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <Triggers><LogonTrigger><Enabled>true</Enabled></LogonTrigger></Triggers>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <RestartOnFailure><Interval>PT1M</Interval><Count>999</Count></RestartOnFailure>
  </Settings>
  <Actions><Exec><Command>%1</Command><Arguments>%2</Arguments></Exec></Actions>
</Task>
XML

#if OS != .WINDOWS {
	install_libc :: #system_library "libc";
	getuid :: () -> u32 #foreign install_libc;
	getenv :: (name: *u8) -> *u8 #foreign install_libc;
}
