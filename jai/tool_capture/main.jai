// capture: records and drives the official Discord desktop client over CDP.
//
//   capture eval  <port> <js>                 evaluate JS in the app page, print JSON
//   capture record <port> <out.jsonl> <secs>  passive recording of one instance
//   capture run   <scenario.scn> [out.jsonl]  run a scenario on the A (9333) / B (9334)
//                                             test instances while recording both
//   capture supervise <minutes>               launch + memory-police the test instances
//   capture instances-stop                    shut the test instances down
//
// Only ever point this at the test instances (ports 9333/9334, launched with
// DISCORD_USER_DATA_DIR inside .secrets/); `check_test_instance` enforces it.
// Raw output contains tokens and must stay in .secrets/raw/.

main :: () {
    args := get_command_line_arguments();
    if args.count < 2 usage();
    cmd := args[1];
    if cmd == "eval" {
        if args.count < 4 usage();
        port := string_to_int(args[2]);
        if !check_test_instance(port) exit(1);
        c, ok := cdp.connect(port);
        if !ok fail("cdp connect failed");
        defer cdp.close(c);
        session, sok := attach_main_page(c);
        if !sok fail("no discord page");
        v, eok := evaluate(c, session, args[3]);
        print("%\n", cdp.to_json(v));
        if !eok exit(1);
    } else if cmd == "record" {
        if args.count < 5 usage();
        port := string_to_int(args[2]);
        if !check_test_instance(port) exit(1);
        exit(xx ifx record_passive(port, args[3], string_to_int(args[4])) then 0 else 1);
    } else if cmd == "supervise" {
        if args.count < 3 usage();
        exit(xx ifx supervise(string_to_int(args[2])) then 0 else 1);
    } else if cmd == "instances-stop" {
        for INSTANCES kill_instance(it, "instances-stop");
    } else if cmd == "run" {
        if args.count < 3 usage();
        exit(xx ifx run_scenario(args[2], ifx args.count > 3 then args[3] else "") then 0 else 1);
    } else {
        usage();
    }
}

usage :: () {
    fail("usage: capture eval <port> <js> | record <port> <out> <secs> | run <scenario.scn> [out] | supervise <min> | instances-stop", 2);
}

fail :: (msg: string, code: s32 = 1) {
    eprint("%\n", msg);
    exit(code);
}

eprint :: (format: string, args: ..Any) { print(format, ..args, to_standard_error = true); }

// command_output runs a command and returns its stdout.
command_output :: (args: ..string) -> string {
    _, out := run_command(..args, capture_and_return_output = true);
    return out;
}

// fields splits s at runs of whitespace, in temp.
fields :: (s: string) -> []string {
    out: [..]string;
    out.allocator = temp;
    i := 0;
    while i < s.count {
        while i < s.count && is_space(s[i]) i += 1;
        j := i;
        while j < s.count && !is_space(s[j]) j += 1;
        if j > i array_add(*out, slice(s, i, j - i));
        i = j;
    }
    return out;
}

// test_instance_pid returns the pid string of the process listening on port when it was started with
// DISCORD_USER_DATA_DIR inside this repo's .secrets/ (never the personal client); "" otherwise.
test_instance_pid :: (port: int, quiet := true) -> string {
    pid := trim(command_output("/usr/sbin/lsof", "-nP", tprint("-iTCP:%", port), "-sTCP:LISTEN", "-t",, temp));
    if !pid {
        if !quiet eprint("nothing listening on %\n", port);
        return "";
    }
    _, pid = split_from_left(pid, #char "\n");
    // ps is setuid, so its exit state may be unreadable; the output is what counts.
    for fields(command_output("/bin/ps", "eww", "-o", "command=", "-p", pid,, temp))
        if begins_with(it, "DISCORD_USER_DATA_DIR=") && contains(it, "/fastcord/.secrets/") return pid;
    if !quiet eprint("port % is not a .secrets test instance; refusing\n", port);
    return "";
}

check_test_instance :: (port: int) -> bool { return test_instance_pid(port, quiet = false) != ""; }

// attach_main_page attaches (flattened) to the Discord app page and returns its session id.
attach_main_page :: (c: *cdp.Client) -> session: string, ok: bool {
    targets, ok := cdp.call_value(c, "Target.getTargets");
    if !ok return "", false;
    infos := cdp.get(targets, "targetInfos");
    if infos.kind != .List return "", false;
    for t: infos.list {
        if cdp.str(t, "type") != "page" continue;
        url := cdp.str(t, "url");
        if !begins_with(url, "https://discord.com/") && !begins_with(url, "https://canary.discord.com/") continue;
        if contains(url, "/overlay") || contains(url, "popout") continue;
        r, rok := cdp.call_value(c, "Target.attachToTarget", tprint("{\"targetId\":%,\"flatten\":true}", cdp.quote(cdp.str(t, "targetId"))));
        if !rok return "", false;
        return copy_string(cdp.str(r, "sessionId")), true;
    }
    return "", false;
}

// evaluate runs a JS expression in the page and returns its value (in temp).
evaluate :: (c: *cdp.Client, session: string, expr: string, quiet := false) -> etf.Value, bool {
    params := tprint("{\"expression\":%,\"returnByValue\":true,\"awaitPromise\":true}", cdp.quote(expr));
    r, ok := cdp.call_value(c, "Runtime.evaluate", params, session);
    if !ok return .{}, false;
    _, has := cdp.get(r, "exceptionDetails");
    if has {
        if !quiet eprint("js exception: %\n", cdp.str(r, "exceptionDetails", "exception", "description"));
        return .{}, false;
    }
    v := cdp.get(r, "result", "value");
    return v, true;
}

// open_private opens a file only this user can read (raw captures and logs hold tokens).
open_private :: (path: string, append := false) -> s32 {
    return open(temp_c_string(path), cast(s32) (O_WRONLY | O_CREAT | (ifx append then O_APPEND else O_TRUNC)), S_IRUSR | S_IWUSR);
}

write_all :: (fd: s32, s: string) {
    left := s;
    while left {
        n := write(fd, left.data, cast(u64) left.count);
        if n <= 0 return;
        advance(*left, n);
    }
}
