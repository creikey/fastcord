// Supervisor for the two official TEST instances.
//
//   capture supervise <minutes>   launch A/B if not running, watch memory, shut both down at the end
//   capture instances-stop        shut both test instances down now
//
// Launch: DISCORD_USER_DATA_DIR=<repo>/.secrets/discord-profile-{a,b} (Discord appends
// "/discord" itself; that is where the logged-in profiles live), --multi-instance,
// --remote-debugging-port=9333/9334, output to .secrets/discord-{a,b}.log.
// Never --user-data-dir (Discord ignores it and opens the user's real profile).
// Each launch also writes a netlog: .secrets/raw/netlog_{a,b}_<unix>.json, the
// current path in .secrets/raw/netlog_{a,b}.latest. Chrome rewrites the file
// on exit without the events, so before stopping an instance the supervisor
// copies it to netlog_{a,b}_<unix>.events.json — pass that one to scrub.
//
// Every POLL: total RSS of each instance's process tree; a tree above
// TREE_LIMIT is killed, and when free+inactive system memory drops below
// SYSTEM_LOW the larger tree is killed. Only processes in a tree whose root
// listens on the test port AND carries the .secrets DISCORD_USER_DATA_DIR are
// ever signalled. Stop early by creating .secrets/supervise.stop.

REPO :: "/Users/creikey/Documents/fastcord";
DISCORD_BIN :: "/Applications/Discord.app/Contents/MacOS/Discord";
TREE_LIMIT :: 2560 * 1024 * 1024; // bytes
SYSTEM_LOW :: 1536 * 1024 * 1024;
POLL :: 3 * time.Second;
STOP_FILE :: REPO + "/.secrets/supervise.stop";

Instance :: struct {
	name: string;
	port: int;
}

INSTANCES := Instance.[.{"a", PORT_A}, .{"b", PORT_B}];
#scope_module

sup_log :: (format: string, args: ..Any) {
	line := fmt.tprintf("%v %s\n", time.now(), fmt.tprintf(format, ..args));
	os.write_string(os.stdout, line);
	{ f, err := os.open(REPO + "/.secrets/supervise.log", .{.Write, .Create, .Append}, .{.Read_User, .Write_User});
	if err == null {
		os.write_string(f, line);
		os.close(f);
	} }
}
#scope_export

// instance_root returns the pid of the verified test instance listening on port (0 = none).
instance_root :: (port: int) -> int {
	_, out, _, err := os.process_exec(.{command = .{"/usr/sbin/lsof", "-nP", fmt.tprintf("-iTCP:%d", port), "-sTCP:LISTEN", "-t"}}, temp);
	if err != null { return 0; }
	s := strings.trim_space(as_string(out));
	if s == "" { return 0; }
	{ i := strings.index_byte(s, 10);
	if i >= 0 { s = sub(s, 0, i); } }
	pid, _ := strconv.parse_int(s);
	_, env_out, _, _ := os.process_exec(.{command = .{"/bin/ps", "eww", "-o", "command=", "-p", s}}, temp);
	for field: strings.fields(as_string(env_out), temp) {
		if strings.has_prefix(field, "DISCORD_USER_DATA_DIR=") && strings.contains(field, "/fastcord/.secrets/") { return pid; }
	}
	return 0;
}

Proc_Row :: struct {
	pid, ppid, rss_kb: int;
}
#scope_module

proc_table :: () -> []Proc_Row {
	_, out, _, _ := os.process_exec(.{command = .{"/bin/ps", "-axo", "pid=,ppid=,rss="}}, temp);
	rows := make_dynamic(Proc_Row, 0, 0, temp);
	for line: strings.split_lines(as_string(out), temp) {
		f := strings.fields(line, temp);
		if len(f) != 3 { continue; }
		a, _ := strconv.parse_int(f[0]);
		b, _ := strconv.parse_int(f[1]);
		c, _ := strconv.parse_int(f[2]);
		append(*rows, Proc_Row.{a, b, c});
	}
	return view(rows);
}
#scope_export

// tree returns root and all its descendants, plus their total RSS in bytes.
tree :: (root: int) -> []int, int {
	pids: []int;
	rss: int;
	rows := proc_table();
	list := make_dynamic(int, 0, 0, temp);
	append(*list, root);
	for i: 0..len(list)-1 {
		for r: rows {
			if r.ppid == get(list, i) { append(*list, r.pid); }
		}
	}
	for p: list {
		for r: rows { if r.pid == p { rss += r.rss_kb * 1024; } }
	}
	return view(list), rss;
}
#scope_module

signal_tree :: (pids: []int, sig: string) {
	cmd := make_dynamic(string, 0, 0, temp);
	append(*cmd, "/bin/kill", sig);
	for p: pids { append(*cmd, fmt.tprintf("%d", p)); }
	_, _, _, _ = os.process_exec(.{command = view(cmd)}, temp);
}
#scope_export

// kill_instance terminates one verified test instance's process tree.
kill_instance :: (inst: Instance, why: string) {
	root := instance_root(inst.port);
	if root == 0 { return; }
	// Chrome rewrites the netlog on shutdown and drops the event stream, so
	// keep a copy of what it wrote while running: <netlog>.events.json
	{ latest, lerr := os.read_entire_file(fmt.tprintf("%s/.secrets/raw/netlog_%s.latest", REPO, inst.name), temp);
	if lerr == null {
		src := strings.trim_space(as_string(latest));
		dst := strings.concatenate(.{strings.trim_suffix(src, ".json"), ".events.json"}, temp);
		{ data, rerr := os.read_entire_file(src, context.allocator);
		if rerr == null {
			os.write_entire_file(dst, data);
			sup_log("netlog snapshot %s (%d MB)", dst, len(data) >> 20);
			delete(data);
		} }
	} }
	pids, rss := tree(root);
	sup_log("stopping %s (pid %d, %d procs, %.0f MB): %s", inst.name, root, len(pids), cast(float64)(rss) / (1 << 20), why);
	signal_tree(pids, "-TERM");
	for _: 0..49 {
		time.sleep(200 * time.Millisecond);
		if instance_root(inst.port) == 0 { break; }
	}
	// anything left of that tree gets SIGKILL
	left := make_dynamic(int, 0, 0, temp);
	rows := proc_table();
	for p: pids { for r: rows { if r.pid == p { append(*left, p); } } }
	if len(left) > 0 { signal_tree(view(left), "-KILL"); }
}

launch_instance :: (inst: Instance) -> bool {
	if instance_root(inst.port) != 0 { return true; }
	env, _ := os.environ(temp);
	full := make_dynamic(string, 0, 0, temp);
	for e: env { if !strings.has_prefix(e, "DISCORD_USER_DATA_DIR=") { append(*full, e); } }
	append(*full, fmt.tprintf("DISCORD_USER_DATA_DIR=%s/.secrets/discord-profile-%s", REPO, inst.name));
	logf, lerr := os.open(fmt.tprintf("%s/.secrets/discord-%s.log", REPO, inst.name), .{.Write, .Create, .Append}, .{.Read_User, .Write_User});
	if lerr != null { return false; }
	defer os.close(logf);
	// Netlog in the default capture mode: request header order and values,
	// h2/h3 session facts; cookie/authorization values are stripped by Chrome,
	// no socket bytes (the Everything mode grew to ~2 GB). Stays in .secrets.
	netlog := fmt.tprintf("%s/.secrets/raw/netlog_%s_%d.json", REPO, inst.name, time.time_to_unix(time.now()));
	os.write_entire_file(fmt.tprintf("%s/.secrets/raw/netlog_%s.latest", REPO, inst.name), transmute([]u8, netlog));
	p, err := os.process_start(
		.{
			command = .{DISCORD_BIN, "--multi-instance", fmt.tprintf("--remote-debugging-port=%d", inst.port), fmt.tprintf("--log-net-log=%s", netlog)},
			env = view(full),
			stdout = logf,
			stderr = logf
		},
	);
	if err != null {
		sup_log("launch %s failed: %v", inst.name, err);
		return false;
	}
	sup_log("launched %s (pid %d) on port %d", inst.name, p.pid, inst.port);
	for _: 0..119 {
		time.sleep(500 * time.Millisecond);
		if instance_root(inst.port) != 0 { return true; }
	}
	sup_log("%s never started listening on %d", inst.name, inst.port);
	return false;
}

// system_available returns free+inactive+purgeable memory in bytes (vm_stat).
system_available :: () -> int {
	_, out, _, _ := os.process_exec(.{command = .{"/usr/bin/vm_stat"}}, temp);
	page := 16384;
	total := 0;
	for line: strings.split_lines(as_string(out), temp) {
		if strings.contains(line, "page size of") {
			for f: strings.fields(line, temp) { { n, ok := strconv.parse_int(f);
if ok { page = n; } } }
		}
		for key: (string.["Pages free:", "Pages inactive:", "Pages purgeable:", "Pages speculative:"]) {
			if strings.has_prefix(line, key) {
				v := strings.trim_right(strings.trim_space(sub_from(line, len(key))), ".");
				n, _ := strconv.parse_int(v);
				total += n;
			}
		}
	}
	return total * page;
}

supervise :: (minutes: int) -> bool {
	os.remove_(STOP_FILE);
	for inst: INSTANCES { if !launch_instance(inst) { return false; } }
	start := time.tick_now();
	last_report := time.tick_now();
	while time.tick_since(start) < time.Duration(minutes) * time.Minute {
		if os.exists(STOP_FILE) {
			sup_log("stop file present");
			break;
		}
		sizes: [2]int;
		roots: [2]int;
		for inst, i: INSTANCES {
			roots[i] = instance_root(inst.port);
			if roots[i] == 0 { continue; }
			_, at(*sizes, i).* = tree(roots[i]);
			if get(sizes, i) > TREE_LIMIT {
				kill_instance(inst, fmt.tprintf("tree RSS %.0f MB > limit", cast(float64)(get(sizes, i)) / (1 << 20)));
				at(*sizes, i).* = 0;
			}
		}
		avail := system_available();
		if avail < SYSTEM_LOW {
			big := ifx get(sizes, 0) >= get(sizes, 1) then 0 else 1;
			if get(sizes, big) > 0 { kill_instance(INSTANCES[big], fmt.tprintf("system memory low (%.0f MB available)", cast(float64)(avail) / (1 << 20))); }
		}
		if time.tick_since(last_report) > 30 * time.Second {
			sup_log("rss a=%.0f MB b=%.0f MB, system available %.0f MB", cast(float64)(get(sizes, 0)) / (1 << 20), cast(float64)(get(sizes, 1)) / (1 << 20), cast(float64)(avail) / (1 << 20));
			last_report = time.tick_now();
		}
		if roots[0] == 0 && roots[1] == 0 {
			sup_log("both instances gone");
			break;
		}
		free_all(temp);
		time.sleep(POLL);
	}
	for inst: INSTANCES { kill_instance(inst, "supervision finished"); }
	return true;
}

