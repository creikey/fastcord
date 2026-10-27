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
TREE_LIMIT :: 2560 * 1024 * 1024;  // bytes
SYSTEM_LOW :: 1536 * 1024 * 1024;
POLL_MS :: 3_000;
STOP_FILE :: #run join(REPO, "/.secrets/supervise.stop");

Instance :: struct {
    name: string;
    port: int;
}

INSTANCES :: Instance.[.{"a", PORT_A}, .{"b", PORT_B}];

MB :: (bytes: int) -> FormatFloat #expand { return formatFloat(cast(float64) bytes / (1 << 20), trailing_width = 0); }

sup_log :: (format: string, args: ..Any) {
    line := tprint("% %\n", calendar_to_string(to_calendar(current_time_consensus(), .LOCAL)), tprint(format, ..args));
    print(line);
    fd := open_private(join(REPO, "/.secrets/supervise.log",, temp), append = true);
    if fd < 0 return;
    write_all(fd, line);
    close(fd);
}

// instance_root returns the pid of the verified test instance listening on port (0 = none).
instance_root :: (port: int) -> int { return string_to_int(test_instance_pid(port)); }

Proc_Row :: struct { pid, ppid, rss_kb: int; }

proc_table :: () -> []Proc_Row {
    rows: [..]Proc_Row;
    rows.allocator = temp;
    for line: split(command_output("/bin/ps", "-axo", "pid=,ppid=,rss=",, temp), "\n",, temp) {
        f := fields(line);
        if f.count == 3 array_add(*rows, .{string_to_int(f[0]), string_to_int(f[1]), string_to_int(f[2])});
    }
    return rows;
}

// tree returns root and all its descendants, plus their total RSS in bytes.
tree :: (root: int) -> pids: []int, rss: int {
    rows := proc_table();
    list: [..]int;
    list.allocator = temp;
    array_add(*list, root);
    i := 0;
    while i < list.count {
        for rows if it.ppid == list[i] array_add(*list, it.pid);
        i += 1;
    }
    rss := 0;
    for p: list for rows if it.pid == p rss += it.rss_kb * 1024;
    return list, rss;
}

signal_tree :: (pids: []int, sig: string) {
    cmd: [..]string;
    cmd.allocator = temp;
    array_add(*cmd, "/bin/kill", sig);
    for pids array_add(*cmd, tprint("%", it));
    run_command(..cmd);
}

// kill_instance terminates one verified test instance's process tree.
kill_instance :: (inst: Instance, why: string) {
    root := instance_root(inst.port);
    if root == 0 return;
    // Chrome rewrites the netlog on shutdown and drops the event stream, so
    // keep a copy of what it wrote while running: <netlog>.events.json
    latest, lok := read_entire_file(tprint("%/.secrets/raw/netlog_%.latest", REPO, inst.name), log_errors = false);
    if lok {
        src := trim(latest);
        dst := join(ifx ends_with(src, ".json") then slice(src, 0, src.count - 5) else src, ".events.json",, temp);
        data, rok := read_entire_file(src, log_errors = false);
        if rok {
            write_entire_file(dst, data);
            sup_log("netlog snapshot % (% MB)", dst, data.count >> 20);
            free(data);
        }
    }
    pids, rss := tree(root);
    sup_log("stopping % (pid %, % procs, % MB): %", inst.name, root, pids.count, MB(rss), why);
    signal_tree(pids, "-TERM");
    for 1..50 {
        sleep_milliseconds(200);
        if instance_root(inst.port) == 0 break;
    }
    // anything left of that tree gets SIGKILL
    left: [..]int;
    left.allocator = temp;
    rows := proc_table();
    for p: pids for rows if it.pid == p array_add(*left, p);
    if left.count signal_tree(left, "-KILL");
}

launch_instance :: (inst: Instance) -> bool {
    if instance_root(inst.port) != 0 return true;
    // Netlog in the default capture mode: request header order and values,
    // h2/h3 session facts; cookie/authorization values are stripped by Chrome,
    // no socket bytes (the Everything mode grew to ~2 GB). Stays in .secrets.
    netlog := tprint("%/.secrets/raw/netlog_%_%.json", REPO, inst.name, to_seconds(current_time_consensus() - APOLLO_TIME_FOR_JAN_1_1970));
    write_entire_file(tprint("%/.secrets/raw/netlog_%.latest", REPO, inst.name), netlog);
    // The shell creates the log private, then becomes Discord with the test profile in its
    // environment and stdout/stderr appended to the log.
    SCRIPT :: "(umask 077; : >>\"$1\"); exec /usr/bin/env DISCORD_USER_DATA_DIR=\"$2\" \"$3\" --multi-instance \"$4\" \"$5\" >>\"$1\" 2>&1";
    p: Process;
    ok := create_process(*p, "/bin/sh", "-c", SCRIPT, "sh", tprint("%/.secrets/discord-%.log", REPO, inst.name),
        tprint("%/.secrets/discord-profile-%", REPO, inst.name), DISCORD_BIN, tprint("--remote-debugging-port=%", inst.port),
        tprint("--log-net-log=%", netlog), kill_process_if_parent_exits = false);
    if !ok {
        sup_log("launch % failed", inst.name);
        return false;
    }
    sup_log("launched % (pid %) on port %", inst.name, p.pid, inst.port);
    for 1..120 {
        sleep_milliseconds(500);
        if instance_root(inst.port) != 0 return true;
    }
    sup_log("% never started listening on %", inst.name, inst.port);
    return false;
}

// system_available returns free+inactive+purgeable memory in bytes (vm_stat).
system_available :: () -> int {
    page, total := 16384, 0;
    for line: split(command_output("/usr/bin/vm_stat",, temp), "\n",, temp) {
        if contains(line, "page size of") for fields(line) {
            n, ok, rest := string_to_int(it);
            if ok && !rest page = n;
        }
        for key: string.["Pages free:", "Pages inactive:", "Pages purgeable:", "Pages speculative:"]
            if begins_with(line, key) total += string_to_int(trim_right(trim(slice(line, key.count, line.count - key.count)), "."));
    }
    return total * page;
}

supervise :: (minutes: int) -> bool {
    file_delete(STOP_FILE);
    for INSTANCES if !launch_instance(it) return false;
    start := current_time_monotonic();
    last_report := start;
    while to_milliseconds(current_time_monotonic() - start) < minutes * 60_000 {
        if file_exists(STOP_FILE) {
            sup_log("stop file present");
            break;
        }
        sizes, roots: [2]int;
        for inst, i: INSTANCES {
            roots[i] = instance_root(inst.port);
            if roots[i] == 0 continue;
            _, sizes[i] = tree(roots[i]);
            if sizes[i] > TREE_LIMIT {
                kill_instance(inst, tprint("tree RSS % MB > limit", MB(sizes[i])));
                sizes[i] = 0;
            }
        }
        avail := system_available();
        if avail < SYSTEM_LOW {
            big := ifx sizes[0] >= sizes[1] then 0 else 1;
            if sizes[big] > 0 kill_instance(INSTANCES[big], tprint("system memory low (% MB available)", MB(avail)));
        }
        if to_milliseconds(current_time_monotonic() - last_report) > 30_000 {
            sup_log("rss a=% MB b=% MB, system available % MB", MB(sizes[0]), MB(sizes[1]), MB(avail));
            last_report = current_time_monotonic();
        }
        if roots[0] == 0 && roots[1] == 0 {
            sup_log("both instances gone");
            break;
        }
        reset_temporary_storage();
        sleep_milliseconds(POLL_MS);
    }
    for INSTANCES kill_instance(it, "supervision finished");
    return true;
}
