package capture

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

// Supervisor for the two official TEST instances.
//
//   capture supervise <minutes>   launch A/B if not running, watch memory, shut both down at the end
//   capture instances-stop        shut both test instances down now
//
// Launch: DISCORD_USER_DATA_DIR=<repo>/.secrets/discord-profile-{a,b} (Discord appends
// "/discord" itself; that is where the logged-in profiles live), --multi-instance,
// --remote-debugging-port=9333/9334, output to .secrets/discord-{a,b}.log.
// Never --user-data-dir (Discord ignores it and opens the user's real profile).
//
// Every POLL: total RSS of each instance's process tree; a tree above
// TREE_LIMIT is killed, and when free+inactive system memory drops below
// SYSTEM_LOW the larger tree is killed. Only processes in a tree whose root
// listens on the test port AND carries the .secrets DISCORD_USER_DATA_DIR are
// ever signalled. Stop early by creating .secrets/supervise.stop.

REPO :: "/Users/creikey/Documents/fastcord"
DISCORD_BIN :: "/Applications/Discord.app/Contents/MacOS/Discord"
TREE_LIMIT :: 2560 * 1024 * 1024 // bytes
SYSTEM_LOW :: 1536 * 1024 * 1024
POLL :: 3 * time.Second
STOP_FILE :: REPO + "/.secrets/supervise.stop"

Instance :: struct {
	name: string,
	port: int,
}

INSTANCES := [2]Instance{{"a", PORT_A}, {"b", PORT_B}}

@(private)
sup_log :: proc(format: string, args: ..any) {
	line := fmt.tprintf("%v %s\n", time.now(), fmt.tprintf(format, ..args))
	os.write_string(os.stdout, line)
	if f, err := os.open(REPO + "/.secrets/supervise.log", {.Write, .Create, .Append}, {.Read_User, .Write_User}); err == nil {
		os.write_string(f, line)
		os.close(f)
	}
}

// instance_root returns the pid of the verified test instance listening on port (0 = none).
instance_root :: proc(port: int) -> int {
	_, out, _, err := os.process_exec({command = {"/usr/sbin/lsof", "-nP", fmt.tprintf("-iTCP:%d", port), "-sTCP:LISTEN", "-t"}}, context.temp_allocator)
	if err != nil do return 0
	s := strings.trim_space(string(out))
	if s == "" do return 0
	if i := strings.index_byte(s, '\n'); i >= 0 do s = s[:i]
	pid, _ := strconv.parse_int(s)
	_, env_out, _, _ := os.process_exec({command = {"/bin/ps", "eww", "-o", "command=", "-p", s}}, context.temp_allocator)
	for field in strings.fields(string(env_out), context.temp_allocator) {
		if strings.has_prefix(field, "DISCORD_USER_DATA_DIR=") && strings.contains(field, "/fastcord/.secrets/") do return pid
	}
	return 0
}

Proc_Row :: struct {
	pid, ppid, rss_kb: int,
}

@(private)
proc_table :: proc() -> []Proc_Row {
	_, out, _, _ := os.process_exec({command = {"/bin/ps", "-axo", "pid=,ppid=,rss="}}, context.temp_allocator)
	rows := make([dynamic]Proc_Row, context.temp_allocator)
	for line in strings.split_lines(string(out), context.temp_allocator) {
		f := strings.fields(line, context.temp_allocator)
		if len(f) != 3 do continue
		a, _ := strconv.parse_int(f[0])
		b, _ := strconv.parse_int(f[1])
		c, _ := strconv.parse_int(f[2])
		append(&rows, Proc_Row{a, b, c})
	}
	return rows[:]
}

// tree returns root and all its descendants, plus their total RSS in bytes.
tree :: proc(root: int) -> (pids: []int, rss: int) {
	rows := proc_table()
	list := make([dynamic]int, context.temp_allocator)
	append(&list, root)
	for i := 0; i < len(list); i += 1 {
		for r in rows {
			if r.ppid == list[i] do append(&list, r.pid)
		}
	}
	for p in list {
		for r in rows do if r.pid == p do rss += r.rss_kb * 1024
	}
	return list[:], rss
}

@(private)
signal_tree :: proc(pids: []int, sig: string) {
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, "/bin/kill", sig)
	for p in pids do append(&cmd, fmt.tprintf("%d", p))
	_, _, _, _ = os.process_exec({command = cmd[:]}, context.temp_allocator)
}

// kill_instance terminates one verified test instance's process tree.
kill_instance :: proc(inst: Instance, why: string) {
	root := instance_root(inst.port)
	if root == 0 do return
	pids, rss := tree(root)
	sup_log("stopping %s (pid %d, %d procs, %.0f MB): %s", inst.name, root, len(pids), f64(rss) / (1 << 20), why)
	signal_tree(pids, "-TERM")
	for _ in 0 ..< 50 {
		time.sleep(200 * time.Millisecond)
		if instance_root(inst.port) == 0 do break
	}
	// anything left of that tree gets SIGKILL
	left := make([dynamic]int, context.temp_allocator)
	rows := proc_table()
	for p in pids do for r in rows do if r.pid == p do append(&left, p)
	if len(left) > 0 do signal_tree(left[:], "-KILL")
}

launch_instance :: proc(inst: Instance) -> bool {
	if instance_root(inst.port) != 0 do return true
	env, _ := os.environ(context.temp_allocator)
	full := make([dynamic]string, context.temp_allocator)
	for e in env do if !strings.has_prefix(e, "DISCORD_USER_DATA_DIR=") do append(&full, e)
	append(&full, fmt.tprintf("DISCORD_USER_DATA_DIR=%s/.secrets/discord-profile-%s", REPO, inst.name))
	logf, lerr := os.open(fmt.tprintf("%s/.secrets/discord-%s.log", REPO, inst.name), {.Write, .Create, .Append}, {.Read_User, .Write_User})
	if lerr != nil do return false
	defer os.close(logf)
	p, err := os.process_start(
		{
			command = {DISCORD_BIN, "--multi-instance", fmt.tprintf("--remote-debugging-port=%d", inst.port)},
			env = full[:],
			stdout = logf,
			stderr = logf,
		},
	)
	if err != nil {
		sup_log("launch %s failed: %v", inst.name, err)
		return false
	}
	sup_log("launched %s (pid %d) on port %d", inst.name, p.pid, inst.port)
	for _ in 0 ..< 120 {
		time.sleep(500 * time.Millisecond)
		if instance_root(inst.port) != 0 do return true
	}
	sup_log("%s never started listening on %d", inst.name, inst.port)
	return false
}

// system_available returns free+inactive+purgeable memory in bytes (vm_stat).
system_available :: proc() -> int {
	_, out, _, _ := os.process_exec({command = {"/usr/bin/vm_stat"}}, context.temp_allocator)
	page := 16384
	total := 0
	for line in strings.split_lines(string(out), context.temp_allocator) {
		if strings.contains(line, "page size of") {
			for f in strings.fields(line, context.temp_allocator) do if n, ok := strconv.parse_int(f); ok do page = n
		}
		for key in ([]string{"Pages free:", "Pages inactive:", "Pages purgeable:", "Pages speculative:"}) {
			if strings.has_prefix(line, key) {
				v := strings.trim_right(strings.trim_space(line[len(key):]), ".")
				n, _ := strconv.parse_int(v)
				total += n
			}
		}
	}
	return total * page
}

supervise :: proc(minutes: int) -> bool {
	os.remove(STOP_FILE)
	for inst in INSTANCES do if !launch_instance(inst) do return false
	start := time.tick_now()
	last_report := time.tick_now()
	for time.tick_since(start) < time.Duration(minutes) * time.Minute {
		if os.exists(STOP_FILE) {
			sup_log("stop file present")
			break
		}
		sizes: [2]int
		roots: [2]int
		for inst, i in INSTANCES {
			roots[i] = instance_root(inst.port)
			if roots[i] == 0 do continue
			_, sizes[i] = tree(roots[i])
			if sizes[i] > TREE_LIMIT {
				kill_instance(inst, fmt.tprintf("tree RSS %.0f MB > limit", f64(sizes[i]) / (1 << 20)))
				sizes[i] = 0
			}
		}
		avail := system_available()
		if avail < SYSTEM_LOW {
			big := 0 if sizes[0] >= sizes[1] else 1
			if sizes[big] > 0 do kill_instance(INSTANCES[big], fmt.tprintf("system memory low (%.0f MB available)", f64(avail) / (1 << 20)))
		}
		if time.tick_since(last_report) > 30 * time.Second {
			sup_log("rss a=%.0f MB b=%.0f MB, system available %.0f MB", f64(sizes[0]) / (1 << 20), f64(sizes[1]) / (1 << 20), f64(avail) / (1 << 20))
			last_report = time.tick_now()
		}
		if roots[0] == 0 && roots[1] == 0 {
			sup_log("both instances gone")
			break
		}
		free_all(context.temp_allocator)
		time.sleep(POLL)
	}
	for inst in INSTANCES do kill_instance(inst, "supervision finished")
	return true
}
