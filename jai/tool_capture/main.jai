main :: () {
	args := get_command_line_arguments();
	if len(args) < 2 { usage(); }
	if args[1] == {
	case "eval";
		if len(args) < 4 { usage(); }
		port, _ := strconv.parse_int(args[2]);
		if !check_test_instance(port) { os.exit(1); }
		c, ok := cdp.connect(port);
		if !ok {
			fmt.eprintln("cdp connect failed");
			os.exit(1);
		}
		defer cdp.close(c);
		session, sok := attach_main_page(c);
		if !sok {
			fmt.eprintln("no discord page");
			os.exit(1);
		}
		v, eok := evaluate(c, session, args[3]);
		fmt.println(cdp.to_json(v));
		if !eok { os.exit(1); }
	case "record";
		if len(args) < 5 { usage(); }
		port, _ := strconv.parse_int(args[2]);
		secs, _ := strconv.parse_int(args[4]);
		if !check_test_instance(port) { os.exit(1); }
		os.exit(ifx record_passive(port, args[3], secs) then 0 else 1);
	case "supervise";
		if len(args) < 3 { usage(); }
		mins, _ := strconv.parse_int(args[2]);
		os.exit(ifx supervise(mins) then 0 else 1);
	case "instances-stop";
		for inst: INSTANCES { kill_instance(inst, "instances-stop"); }
	case "run";
		if len(args) < 3 { usage(); }
		out := ifx len(args) > 3 then args[3] else "";
		os.exit(ifx run_scenario(args[2], out) then 0 else 1);
	case;
		usage();
	}
}

usage :: () {
	fmt.eprintln("usage: capture eval <port> <js> | record <port> <out> <secs> | run <scenario.scn> [out] | supervise <min> | instances-stop");
	os.exit(2);
}

// check_test_instance verifies the process listening on port was started with
// DISCORD_USER_DATA_DIR inside this repo's .secrets/ (never the personal client).
check_test_instance :: (port: int) -> bool {
	_, pid_out, _, err := os.process_exec(.{command = .{"/usr/sbin/lsof", "-nP", fmt.tprintf("-iTCP:%d", port), "-sTCP:LISTEN", "-t"}}, temp);
	pid := strings.trim_space(as_string(pid_out));
	if err != null || pid == "" {
		fmt.eprintfln("nothing listening on %d", port);
		return false;
	}
	{ i := strings.index_byte(pid, 10);
	if i >= 0 { pid = sub(pid, 0, i); } }
	_, env_out, _, perr := os.process_exec(.{command = .{"/bin/ps", "eww", "-o", "command=", "-p", pid}}, temp);
	// ps is setuid, so Odin can't read its exit state (Permission_Denied); the output is fine.
	if perr != null && len(env_out) == 0 {
		fmt.eprintln("ps failed:", perr);
		return false;
	}
	for field: strings.fields(as_string(env_out), temp) {
		if strings.has_prefix(field, "DISCORD_USER_DATA_DIR=") && strings.contains(field, "/fastcord/.secrets/") { return true; }
	}
	fmt.eprintfln("port %d is not a .secrets test instance; refusing", port);
	return false;
}

