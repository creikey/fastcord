// jai build.jai - <target>: see USAGE below.
// Compiles the vendored C libraries (each vendor/<lib>/fc_<lib>.c, or the files listed in fc_<lib>.sources)
// into build/, then the Jai program, then links everything with the system clang.
#import "Basic";
#import "Compiler";
#import "Process";
#import "File";
#import "File_Utilities";
#import "String";
#import "Thread";
#import "System";

#run build();

build :: () {
    set_build_options_dc(.{do_output = false});
    args := get_build_options().compile_time_command_line;
    target := ifx args.count then args[0] else "app";
    make_directory_if_it_does_not_exist("build");
    if !build_c() { log_error("C build failed"); compiler_set_workspace_status(.FAILED); return; }
    APP :: "app :: #import \"app\"; main :: () { app.main(); }";
    ok := true;
    if target == {
        case "c";      return;
        case "app";    ok = compile("fastcord", APP, .VERY_OPTIMIZED);
        case "dev";    ok = compile("fastcord-dev", APP, .OPTIMIZED);
        case "debug";  ok = compile("fastcord-debug", APP, .DEBUG);
        case "tool";   ok = compile(args[1], tprint("t :: #import \"tool_%\"; main :: () { t.main(); }", args[1]));  // a tool is a module with a main
        case "parity"; ok = compile("parity", file = "src/discord_parity/module.jai");
        case "run";    ok = compile(path_strip_extension(path_filename(args[1])), file = args[1]);
        case "test";
            // the offline traffic-parity tests; extra arguments pick tests by name
            ok = compile("test-discord-jai", file = "src/tests/discord.jai", optimization = .OPTIMIZED);
            if ok {
                a: [..]string;
                array_add(*a, "build/test-discord-jai");
                for 1..args.count-1 array_add(*a, args[it]);
                ok = run_command(..a).exit_code == 0;
            }
        case "module"; ok = compile(tprint("sm_%", args[1]), tprint("m :: #import \"%\"; main :: () {}", args[1]));  // type-check one module
        case "ui";     ok = compile("fastcord-dev", APP, .OPTIMIZED) && ui_scripts();
        case "bench";  ok = compile("fastcord-dev", APP, .OPTIMIZED) && bench(args);
        case "check";
            // everything before a commit: the offline parity tests, the UI scripts and sweep, the bench budget, secrets
            ok = compile("test-discord-jai", file = "src/tests/discord.jai", optimization = .OPTIMIZED)
                && run_command("build/test-discord-jai").exit_code == 0
                && compile("fastcord-dev", APP, .OPTIMIZED) && ui_scripts() && bench(.["bench"])
                && run_command("python3", "-I", "tools/check_secrets.py").exit_code == 0;
            print(ifx ok then "check: all passed\n" else "check: FAILED\n");
        case "release"; ok = release(args);
        case "release_x64"; ok = compile("fastcord-x86_64", tprint("app :: #import \"app\"(VERSION = \"%\"); main :: () { app.main(); }", args[1]), .VERY_OPTIMIZED);
        case "og";
            // site/og.jpg, the 1200x630 link preview, from tools/og/card.html with headless Chrome
            ok = run_command("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", "--headless=new", "--disable-gpu",
                    "--hide-scrollbars", "--force-device-scale-factor=1", "--window-size=1200,630", "--screenshot=build/og.png",
                    tprint("file://%/tools/og/card.html", get_working_directory())).exit_code == 0
                && run_command("sips", "-s", "format", "jpeg", "-s", "formatOptions", "88", "build/og.png", "--out", "site/og.jpg").exit_code == 0;
        case; log_error(USAGE); return;
    }
    if !ok compiler_set_workspace_status(.FAILED);
}

USAGE :: #string END
usage: jai build.jai - <target>
  app | dev | debug           the app: build/fastcord, fastcord-dev (optimised + symbols), fastcord-debug
  test [names]                offline traffic-parity tests (substrings pick tests)
  ui                          headless UI scripts (tests/ui) and the dead-control sweep
  bench [name] [save]         UI benchmark against the fixture; "save" keeps it as the local baseline
  check                       test + ui + bench budget + secrets scan: run before committing
  module <name>               type-check one module (every procedure)
  parity                      build/parity (live traffic sessions; human-run only)
  tool <name>                 build/<name> from src/tool_<name>
  run <file.jai>              build any program file
  release <vX.Y.Z> [publish]  dist/fastcord-macos.zip; publish uploads it to the GitHub release
  og                          site/og.jpg (link preview) from tools/og/card.html
  c                           only the vendored C libraries
END

// compile builds one program into build/<name>: the root is a file or a build string.
compile :: (name: string, source := "", optimization := Optimization_Type.DEBUG, file := "", cpu := CPU) -> bool {
    w := compiler_create_workspace(name);
    o := get_build_options(w);
    import_path: [..]string;
    array_add(*import_path, "src");
    for o.import_path array_add(*import_path, it);
    o.import_path = import_path;
    o.use_custom_link_command = true;
    o.text_output_flags = 0;
    o.output_executable_name = name;
    o.output_path = "build";
    o.cpu_target = cpu;
    set_optimization(*o, optimization);   // first: it resets the checks below
    // type-check every procedure, not only the ones called; shipping builds drop the dead ones
    if optimization != .VERY_OPTIMIZED o.dead_code_elimination = .NONE;
    o.cast_bounds_check = .OFF;      // integer casts truncate, as the wire encoders expect
    set_build_options(o, w);
    compiler_begin_intercept(w);
    if file add_build_file(file, w); else add_build_string(source, w);
    ok := true;
    while true {
        m := compiler_wait_for_message();
        if m.kind == .ERROR ok = false;
        if m.kind == .COMPLETE break;
        if m.kind == .PHASE {
            p := cast(*Message_Phase) m;
            if p.phase == .READY_FOR_CUSTOM_LINK_COMMAND {
                if !link(p, tprint("build/%", name), cpu) ok = false;
                compiler_custom_link_command_is_complete(w);
            }
        }
    }
    compiler_end_intercept(w);
    return ok;
}

// release <vX.Y.Z> [publish]: dist/fastcord-macos.zip, a universal (arm64 + x86_64) ad-hoc signed Fastcord.app
// built on this machine (CI has no Jai). With "publish", uploads it to the GitHub release for the tag
// (created at HEAD if missing) with the gh CLI. Run the gates first (README "Releasing").
release :: (args: []string) -> bool {
    if args.count < 2 || !begins_with(args[1], "v") { log_error("release needs a version tag like v0.2.0"); return false; }
    version := args[1];
    root := tprint("app :: #import \"app\"(VERSION = \"%\"); main :: () { app.main(); }", version);
    if !compile("fastcord-arm64", root, .VERY_OPTIMIZED, cpu = .ARM64) return false;
    // The x86_64 half comes from the compiler's own x86_64 slice under Rosetta, not a cross-compile: the
    // ARM compiler can't run Basic's x86 #asm (print, calendar math) in the x86_64 program's #run code.
    if run_command("arch", "-x86_64", get_path_of_running_executable(), "build.jai", "-", "release_x64", version).exit_code != 0 return false;
    app := "build/pkg/Fastcord.app";
    run_command("rm", "-rf", "build/pkg", "dist");
    make_directory_if_it_does_not_exist(tprint("%/Contents/MacOS", app), recursive = true);
    make_directory_if_it_does_not_exist(tprint("%/Contents/Resources", app), recursive = true);
    make_directory_if_it_does_not_exist("dist");
    plain := slice(version, 1, version.count - 1);
    plist := tprint(INFO_PLIST, plain, plain);
    ok := run_command("lipo", "-create", "build/fastcord-arm64", "build/fastcord-x86_64", "-output", tprint("%/Contents/MacOS/Fastcord", app)).exit_code == 0
        && run_command("strip", "-x", tprint("%/Contents/MacOS/Fastcord", app)).exit_code == 0  // local symbols: ~2 MB per arch
        && run_command("cp", "assets/Fastcord.icns", tprint("%/Contents/Resources/", app)).exit_code == 0
        && write_entire_file(tprint("%/Contents/Info.plist", app), plist)
        // ad-hoc signature (required to launch on Apple silicon); not notarized
        && run_command("codesign", "--force", "--deep", "--sign", "-", app).exit_code == 0
        && run_command("ditto", "-c", "-k", "--keepParent", app, "dist/fastcord-macos.zip").exit_code == 0;
    if !ok return false;
    print("dist/fastcord-macos.zip (%)\n", version);
    if args.count < 3 || args[2] != "publish" return true;
    _, head_out := run_command("git", "rev-parse", "HEAD", capture_and_return_output = true);
    head := trim(head_out);
    if run_command("gh", "release", "view", version).exit_code != 0 {
        return run_command("gh", "release", "create", version, "dist/fastcord-macos.zip", "--target", head, "--title", version, "--generate-notes").exit_code == 0;
    }
    return run_command("gh", "release", "upload", version, "dist/fastcord-macos.zip", "--clobber").exit_code == 0;
}

// Runs a program with TZ=UTC (fixed clocks in fixtures), saving its output to log; true on exit 0.
run_logged :: (log: string, args: ..string) -> bool {
    a: [..]string;
    array_add(*a, "/usr/bin/env", "TZ=UTC");
    for args array_add(*a, it);
    r, out, err := run_command(..a, capture_and_return_output = true);
    write_entire_file(log, join(out, err));
    return r.exit_code == 0;
}

// Every tests/ui script (chat fixture), tests/ui/rail (rail fixture) and tests/ui/dm (dm fixture) script and the dead-control sweep, as
// parallel headless processes; results print in a fixed order.
ui_scripts :: () -> bool {
    Job :: struct { name: string; args: [..]string; ok: bool; }
    jobs: [..]Job;
    BIN :: "build/fastcord-dev";
    add :: (jobs: *[..]Job, name: string, fixture: string, script: string) {
        j := array_add(jobs);
        j.name = name;
        array_add(*j.args, BIN, tprint("-shot:build/ui-%.png", path_strip_extension(path_filename(script))), "-dpi:1", "-now:1793016000",
            tprint("-fixture:%", fixture), "-channel:1546820603343016006", tprint("-script:%", script));
    }
    for file_list("tests/ui") if ends_with(it, ".txt") && !ends_with(it, "sweep.txt") && !ends_with(it, "sweep_allow.txt")
        add(*jobs, path_strip_extension(path_filename(it)), "tests/ui/chat.jsonl", it);
    for file_list("tests/ui/rail") if ends_with(it, ".txt")
        add(*jobs, tprint("rail_%", path_strip_extension(path_filename(it))), "tests/ui/rail.jsonl", it);
    for file_list("tests/ui/dm") if ends_with(it, ".txt")
        add(*jobs, tprint("dm_%", path_strip_extension(path_filename(it))), "tests/ui/dm.jsonl", it);
    // emoji scripts: the emoji fixture, with the Twemoji svgs they show served offline
    for file_list("tests/ui/emoji") if ends_with(it, ".txt") {
        add(*jobs, tprint("emoji_%", path_strip_extension(path_filename(it))), "tests/ui/chat_emoji.jsonl", it);
        array_insert_at(*jobs[jobs.count - 1].args, "FASTCORD_MEDIA_DIR=tests/ui/emoji/media", 0);
    }
    sweep := array_add(*jobs);
    sweep.name = "sweep";
    array_add(*sweep.args, BIN, "-shot:build/sweep.png", "-dpi:1", "-now:1793016000", "-sweep:tests/ui/sweep.txt");
    make_directory_if_it_does_not_exist("build/uires");
    threads := NewArray(jobs.count, Thread);
    for * threads {
        thread_init(it, (t: *Thread) -> s64 {
            j := cast(*Job) t.data;
            j.ok = run_logged(tprint("build/uires/%.log", j.name), ..j.args);
            return 0;
        });
        it.data = *jobs[it_index];
        thread_start(it);
    }
    ok := true;
    for * threads { thread_is_done(it, -1); thread_deinit(it); }
    for jobs {
        print("% %\n", ifx it.ok then "PASS" else "FAIL", it.name);
        if !it.ok {
            ok = false;
            log := read_entire_file(tprint("build/uires/%.log", it.name));
            print("    %\n", replace(log, "\n", "\n    "));
        }
    }
    return ok;
}

// The UI benchmark: every tests/bench script headless against the generated heavy fixture, profiled, compared
// with the local baseline and the counter budget (tests/bench/budget.json). See README "Performance".
bench :: (args: []string) -> bool {
    only, save := "", false;
    for 1..args.count-1 { if args[it] == "save" save = true; else only = args[it]; }
    make_directory_if_it_does_not_exist("build/bench");
    if file_modtime_and_size("tests/bench/make_bench_fixture.py") > file_modtime_and_size("build/bench/heavy.jsonl")
        if run_command("python3", "-I", "tests/bench/make_bench_fixture.py", "build/bench/heavy.jsonl").exit_code != 0 return false;
    file_delete("build/bench/latest.jsonl");
    for file_list("tests/bench") {
        if !ends_with(it, ".txt") continue;
        name := path_strip_extension(path_filename(it));
        if only && only != name continue;
        // account.txt starts at home like a fresh launch; the others open the bench channel
        a: [..]string;
        array_add(*a, "FASTCORD_MEDIA_DIR=build/bench/media", "build/fastcord-dev", "-dpi:1", "-now:1793016000",
            "-fixture:build/bench/heavy.jsonl", "-bench:build/bench/latest.jsonl", tprint("-prof:build/bench/%", name), tprint("-script:%", it));
        if name != "account" array_add(*a, "-channel:1600000000000100003");
        if !run_logged(tprint("build/bench/%.log", name), ..a) { print("FAIL % (see build/bench/%.log)\n", it, name); return false; }
    }
    ok := run_command("python3", "-I", "tools/bench_compare.py", "build/bench/latest.jsonl", "--baseline", "build/bench/baseline.jsonl",
        "--budget", "tests/bench/budget.json").exit_code == 0;
    if save { write_entire_file("build/bench/baseline.jsonl", read_entire_file("build/bench/latest.jsonl")); print("saved build/bench/baseline.jsonl\n"); }
    return ok;
}

INFO_PLIST :: #string XML
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key><string>Fastcord</string>
	<key>CFBundleDisplayName</key><string>Fastcord</string>
	<key>CFBundleIdentifier</key><string>com.creikey.fastcord</string>
	<key>CFBundleExecutable</key><string>Fastcord</string>
	<key>CFBundleIconFile</key><string>Fastcord</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>%1</string>
	<key>CFBundleVersion</key><string>%2</string>
	<key>LSMinimumSystemVersion</key><string>13.0</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSMicrophoneUsageDescription</key><string>Fastcord uses the microphone for voice chat.</string>
	<key>LSApplicationCategoryType</key><string>public.app-category.social-networking</string>
</dict>
</plist>
XML

// The C objects are universal (arm64 + x86_64): each Jai program links the slice for its target.
MAC_C_FLAGS :: string.["-arch", "arm64", "-arch", "x86_64", "-mmacosx-version-min=13.0"];

link :: (p: *Message_Phase, exe: string, cpu: CPU_Tag) -> bool {
    a: [..]string;
    array_add(*a, "clang", "-o", exe);
    #if OS == .MACOS array_add(*a, "-arch", ifx cpu == .X64 then "x86_64" else "arm64", "-mmacosx-version-min=13.0");
    array_add(*a, ..p.compiler_generated_object_files);
    array_add(*a, ..p.support_object_files);
    for p.user_libraries array_add(*a, it);
    // Jai lists "-lX" and "-framework", "X" pairs; drop duplicates.
    seen: [..]string;
    libs := p.system_libraries;
    for i: 0..libs.count-1 {
        if i > 0 && libs[i-1] == "-framework" continue;
        arg := ifx libs[i] == "-framework" then tprint("-framework %", libs[i+1]) else libs[i];
        if array_find(seen, arg) continue;
        array_add(*seen, arg);
        if libs[i] == "-framework" array_add(*a, "-framework", libs[i+1]);
        else array_add(*a, libs[i]);
    }
    array_add(*a, "-lc++");
    r := run_command(..a);
    return r.exit_code == 0;
}

vendor_outputs :: () -> [..]string {
    out: [..]string;
    for src: c_units() array_add(*out, obj_of(src));
    for list: source_lists() array_add(*out, tprint("build/lib%.a", path_strip_extension(path_filename(list))));
    return out;
}

c_units :: () -> [..]string {
    out: [..]string;
    for dir: vendor_dirs() {
        files := file_list(dir);
        for files if begins_with(path_filename(it), "fc_") && ends_with(it, ".c") array_add(*out, it);
    }
    return out;
}
source_lists :: () -> [..]string {
    out: [..]string;
    for dir: vendor_dirs() {
        files := file_list(dir);
        for files if begins_with(path_filename(it), "fc_") && ends_with(it, ".sources") array_add(*out, it);
    }
    return out;
}
vendor_dirs :: () -> [..]string {
    out: [..]string;
    visit_files("vendor", false, *out, (info: *File_Visit_Info, out: *[..]string) { array_add(out, copy_string(info.full_name)); }, visit_files = false, visit_directories = true);
    return out;
}
obj_of :: (src: string) -> string { return tprint("build/%.o", path_strip_extension(path_filename(src))); }

// Newest modification time under a directory (and this file), to decide what to rebuild.
newest :: (dir: string) -> Apollo_Time {
    t: Apollo_Time;
    visit_files(dir, true, *t, (info: *File_Visit_Info, t: *Apollo_Time) {
        m := file_modtime_and_size(info.full_name);
        if m > t.* t.* = m;
    });
    return t;
}
stale :: (out: string, dir: string) -> bool {
    m, _, ok := file_modtime_and_size(out);
    return !ok || newest(dir) > m;
}
cflags :: (base: string) -> []string {
    s, ok := read_entire_file(tprint("%.cflags", base), log_errors = false);
    if !ok return .[];
    return break_command_into_strings(trim(s));
}

build_c :: () -> bool {
    jobs: [..][..]string;
    for src: c_units() {
        obj := obj_of(src);
        if !stale(obj, path_strip_filename(src)) continue;
        a: [..]string;
        array_add(*a, "clang", "-c", "-O2");
        #if OS == .MACOS array_add(*a, ..MAC_C_FLAGS);
        array_add(*a, ..cflags(path_strip_extension(src)));
        array_add(*a, "-o", obj, src);
        array_add(*jobs, a);
    }
    archives: [..]string;
    for list: source_lists() {
        name := path_strip_extension(path_filename(list));
        lib := tprint("build/lib%.a", name);
        if !stale(lib, path_strip_filename(list)) continue;
        dir := tprint("build/%", slice(name, 3, name.count - 3));
        make_directory_if_it_does_not_exist(dir);
        text := read_entire_file(list);
        extra := cflags(path_strip_extension(list));
        for line: split(text, "\n") {
            f := trim(line);
            if !f continue;
            a: [..]string;
            array_add(*a, "clang", "-c", "-O2");
            #if OS == .MACOS array_add(*a, ..MAC_C_FLAGS);
            if !ends_with(f, ".c") array_add(*a, "-std=c++17", "-fno-exceptions", "-fno-rtti");
            array_add(*a, ..extra);
            array_add(*a, "-o", tprint("%/%.o", dir, path_filename(f)), f);
            array_add(*jobs, a);
        }
        array_add(*archives, lib, dir);
    }
    if !run_parallel(jobs) return false;
    defer {
        // One archive for the Jai side: every module's `#library,no_dll "../../build/fc_vendor"`.
        a: [..]string;
        array_add(*a, "libtool", "-static", "-o", "build/fc_vendor.a");
        for vendor_outputs() array_add(*a, it);
        m, _, ok := file_modtime_and_size("build/fc_vendor.a");
        need := !ok;
        for vendor_outputs() { t := file_modtime_and_size(it); if t > m need = true; }
        if need run_command(..a);
    }
    for i: 0..archives.count/2-1 {
        lib, dir := archives[i*2], archives[i*2+1];
        file_delete(lib);
        objs: [..]string;
        array_add(*objs, "libtool", "-static", "-o", lib);
        for file_list(dir) if ends_with(it, ".o") array_add(*objs, it);
        if run_command(..objs).exit_code != 0 return false;
    }
    return true;
}

run_parallel :: (jobs: [][..]string) -> bool {
    if !jobs return true;
    n := max(get_number_of_processors() - 1, 1);
    running: [..]Process;
    next, ok := 0, true;
    while next < jobs.count || running.count {
        while next < jobs.count && running.count < n {
            print("cc %\n", jobs[next][jobs[next].count - 1]);
            p: Process;
            if !create_process(*p, ..jobs[next]) { ok = false; }
            else array_add(*running, p);
            next += 1;
        }
        p := *running[0];
        _, r := get_process_result(p);
        if r.exit_code != 0 ok = false;
        deinit(p);
        array_ordered_remove_by_index(*running, 0);
    }
    return ok;
}

#import "System";
