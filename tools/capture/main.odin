// capture: records and drives the official Discord desktop client over CDP.
//
//   capture eval  <port> <js>                 evaluate JS in the app page, print JSON
//   capture record <port> <out.jsonl> <secs>  passive recording of one instance
//   capture run   <scenario.scn> [out.jsonl]  run a scenario on the A (9333) / B (9334)
//                                             test instances while recording both
//
// Only ever point this at the test instances (ports 9333/9334, launched with
// DISCORD_USER_DATA_DIR inside .secrets/); `check_test_instance` enforces it.
// Raw output contains tokens and must stay in .secrets/raw/.
package capture

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "cdp"

main :: proc() {
	args := os.args
	if len(args) < 2 do usage()
	switch args[1] {
	case "eval":
		if len(args) < 4 do usage()
		port, _ := strconv.parse_int(args[2])
		if !check_test_instance(port) do os.exit(1)
		c, ok := cdp.connect(port)
		if !ok {
			fmt.eprintln("cdp connect failed")
			os.exit(1)
		}
		defer cdp.close(c)
		session, sok := attach_main_page(c)
		if !sok {
			fmt.eprintln("no discord page")
			os.exit(1)
		}
		v, eok := evaluate(c, session, args[3])
		fmt.println(cdp.to_json(v))
		if !eok do os.exit(1)
	case "record":
		if len(args) < 5 do usage()
		port, _ := strconv.parse_int(args[2])
		secs, _ := strconv.parse_int(args[4])
		if !check_test_instance(port) do os.exit(1)
		os.exit(record_passive(port, args[3], secs) ? 0 : 1)
	case "run":
		if len(args) < 3 do usage()
		out := args[3] if len(args) > 3 else ""
		os.exit(run_scenario(args[2], out) ? 0 : 1)
	case:
		usage()
	}
}

usage :: proc() -> ! {
	fmt.eprintln("usage: capture eval <port> <js> | record <port> <out> <secs> | run <scenario.scn> [out]")
	os.exit(2)
}

// check_test_instance verifies the process listening on port was started with
// DISCORD_USER_DATA_DIR inside this repo's .secrets/ (never the personal client).
check_test_instance :: proc(port: int) -> bool {
	_, pid_out, _, err := os.process_exec({command = {"/usr/sbin/lsof", "-nP", fmt.tprintf("-iTCP:%d", port), "-sTCP:LISTEN", "-t"}}, context.temp_allocator)
	pid := strings.trim_space(string(pid_out))
	if err != nil || pid == "" {
		fmt.eprintfln("nothing listening on %d", port)
		return false
	}
	if i := strings.index_byte(pid, '\n'); i >= 0 do pid = pid[:i]
	_, env_out, _, perr := os.process_exec({command = {"/bin/ps", "eww", "-o", "command=", "-p", pid}}, context.temp_allocator)
	// ps is setuid, so Odin can't read its exit state (Permission_Denied); the output is fine.
	if perr != nil && len(env_out) == 0 {
		fmt.eprintln("ps failed:", perr)
		return false
	}
	for field in strings.fields(string(env_out), context.temp_allocator) {
		if strings.has_prefix(field, "DISCORD_USER_DATA_DIR=") && strings.contains(field, "/fastcord/.secrets/") do return true
	}
	fmt.eprintfln("port %d is not a .secrets test instance; refusing", port)
	return false
}
