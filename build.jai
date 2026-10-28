// jai build.jai - <target>: see USAGE below.
// Compiles the vendored C libraries (each vendor/<lib>/fc_<lib>.c, or the files listed in fc_<lib>.sources)
// into build/, then the Jai program, then links everything. The C, and the macOS and Linux links, go through one pinned Zig that build/zig caches.
#import "Basic";
#import "Compiler";
#import "Process";
#import "File";
#import "File_Utilities";
#import "String";
#import "Thread";
#import "System";
#if OS == .WINDOWS WR :: #import "Windows_Resources";

#run build();

build :: () {
    set_build_options_dc(.{do_output = false});
    args := get_build_options().compile_time_command_line;
    if args.count && args[args.count-1] == "linux" { LINUX = true; args.count -= 1; }
    target := ifx args.count then args[0] else "app";
    make_directory_if_it_does_not_exist(OBJ(), recursive = true);
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
                array_add(*a, built("test-discord-jai"));
                for 1..args.count-1 array_add(*a, args[it]);
                ok = run_command(..a).exit_code == 0;
            }
        case "module"; ok = compile(tprint("sm_%", args[1]), tprint("m :: #import \"%\"; main :: () {}", args[1]));  // type-check one module
        case "ui";     ok = compile("fastcord-dev", APP, .OPTIMIZED) && ui_scripts();
        case "bench";  ok = compile("fastcord-dev", APP, .OPTIMIZED) && bench(args);
        case "check-full";
            // the overall check, run only on request: the offline parity tests, the UI scripts and sweep, the bench budget, secrets
            ok = compile("test-discord-jai", file = "src/tests/discord.jai", optimization = .OPTIMIZED)
                && run_command(built("test-discord-jai")).exit_code == 0
                && compile("fastcord-dev", APP, .OPTIMIZED) && ui_scripts() && bench(.["bench"])
                && run_command(PYTHON, "-I", "tools/check_secrets.py").exit_code == 0;
            print(ifx ok then "check-full: all passed\n" else "check-full: FAILED\n");
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
  check-full                  test + ui + bench budget + secrets scan (~3 min): only on request
  module <name>               type-check one module (every procedure)
  parity                      build/parity (live traffic sessions; human-run only)
  tool <name>                 build/<name> from src/tool_<name>
  run <file.jai>              build any program file
  release <vX.Y.Z>            dist/: the Mac app on macOS, Windows + Linux on Windows (CI publishes them)
  og                          site/og.jpg (link preview) from tools/og/card.html
  c                           only the vendored C libraries
  <target> linux              any target cross-compiled for x86_64 Linux (from Windows or macOS)
END

// A trailing "linux" argument (implied on a Linux host) builds everything for x86_64 Linux: the C with `zig cc` against
// glibc 2.17 (so one binary runs on every distro since 2014), the Jai with os_target = .LINUX.
LINUX := OS == .LINUX;
GLIBC :: "x86_64-linux-gnu.2.17";
// Native macOS compiles the C once per arch ("aarch64", "x86_64") and joins the two archives with lipo.
MAC_ARCH := "";
OBJ :: () -> string {
    if LINUX return "build/linux";
    if MAC_ARCH return tprint("build/mac-%", MAC_ARCH);
    return "build";
}
VENDOR_LIB :: () -> string {
    #if OS == .WINDOWS if !LINUX return "build/fc_vendor.lib";
    if MAC_ARCH return tprint("%/fc_vendor.a", OBJ());
    return "build/fc_vendor.a";
}
// A program built into build/, as a path CreateProcess / exec take.
built :: (name: string) -> string { #if OS == .WINDOWS return join("build\\", name, ".exe",, temp); else return tprint("build/%", name); }

// compile builds one program into build/<name>: the root is a file or a build string.
compile :: (name: string, source := "", optimization := Optimization_Type.DEBUG, file := "", cpu := CPU, gui := false) -> bool {
    w := compiler_create_workspace(name);
    o := get_build_options(w);
    import_path: [..]string;
    array_add(*import_path, "src");
    for o.import_path array_add(*import_path, it);
    o.import_path = import_path;
    if LINUX o.os_target = .LINUX;
    // Windows links with the compiler's own linker step (MSVC libraries); macOS and Linux with zig
    o.use_custom_link_command = OS != .WINDOWS || LINUX;
    o.text_output_flags = 0;
    o.output_executable_name = name;
    o.output_path = "build";
    o.cpu_target = cpu;
    set_optimization(*o, optimization);   // first: it resets the checks below
    // set_optimization turns split modules off for inlining, leaving LLVM one thread: dev builds 87 s -> 19 s,
    // bench latency unchanged, UI pass ~25% slower than unsplit
    if optimization == .OPTIMIZED o.llvm_options.enable_split_modules = true;
    // `- module` and debug type-check every procedure, not only the ones called; dev and shipping drop the dead ones
    if optimization == .DEBUG o.dead_code_elimination = .NONE;
    o.cast_bounds_check = .OFF;      // integer casts truncate, as the wire encoders expect
    set_build_options(o, w);
    // a release exe opens no console window (Windows only; dev builds keep printing to it)
    #if OS == .WINDOWS if gui && !LINUX WR.disable_runtime_console(w);
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
    // Every Windows build of the app gets the icon; the window loads it from the exe as resource 2. Right
    // after the link the exe can still be held open (EndUpdateResource fails with error 110), so retry.
    #if OS == .WINDOWS if ok && !LINUX && begins_with(source, "app :: #import \"app\"") {
        for 1..30 {
            ok = WR.set_icon_by_filename(tprint("build/%.exe", name), "assets/fastcord.ico");
            if ok break;
            sleep_milliseconds(200);
        }
    }
    return ok;
}

// release <vX.Y.Z>: the release archives this machine can build: on macOS dist/fastcord-macos.zip, a
// universal (arm64 + x86_64) ad-hoc signed Fastcord.app; on Windows dist/fastcord-windows.zip (Fastcord.exe)
// and dist/fastcord-linux-x86_64.tar.gz (cross-compiled). CI's release workflow uploads them.
release :: (args: []string) -> bool {
    if args.count < 2 || !begins_with(args[1], "v") { log_error("release needs a version tag like v0.2.0"); return false; }
    version := args[1];
    root := tprint("app :: #import \"app\"(VERSION = \"%\"); main :: () { app.main(); }", version);
    make_directory_if_it_does_not_exist("dist");
    assets: [..]string;
    #if OS == .MACOS {
        if !compile("fastcord-arm64", root, .VERY_OPTIMIZED, cpu = .ARM64) return false;
        // The x86_64 half comes from the compiler's own x86_64 slice under Rosetta, not a cross-compile: the
        // ARM compiler can't run Basic's x86 #asm (print, calendar math) in the x86_64 program's #run code.
        if run_command("arch", "-x86_64", get_path_of_running_executable(), "build.jai", "-", "release_x64", version).exit_code != 0 return false;
        app := "build/pkg/Fastcord.app";
        run_command("rm", "-rf", "build/pkg", "dist/fastcord-macos.zip");
        make_directory_if_it_does_not_exist(tprint("%/Contents/MacOS", app), recursive = true);
        make_directory_if_it_does_not_exist(tprint("%/Contents/Resources", app), recursive = true);
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
        array_add(*assets, "dist/fastcord-macos.zip");
    } else #if OS == .WINDOWS {
        // Windows: a GUI-subsystem exe (no console window) with the icon, zipped with the system bsdtar
        if !compile("Fastcord", root, .VERY_OPTIMIZED, gui = true) return false;
        file_delete("dist/fastcord-windows.zip");
        if run_command("tar", "-a", "-c", "-f", "dist/fastcord-windows.zip", "-C", "build", "Fastcord.exe").exit_code != 0 return false;
        array_add(*assets, "dist/fastcord-windows.zip");
        // Linux x86_64, cross-compiled: one binary for every distro (glibc 2.17+, every system library opened
        // at run time), packaged with its desktop entry and icon by tools/package_linux.py
        LINUX = true;
        defer LINUX = false;
        if !build_c() || !compile("fastcord-linux", root, .VERY_OPTIMIZED) return false;
        if run_command("llvm-objcopy", "--strip-debug", "build/fastcord-linux", "build/fastcord-linux.stripped").exit_code != 0 return false;
        if run_command(PYTHON, "-I", "tools/package_linux.py", "build/fastcord-linux.stripped", "dist/fastcord-linux-x86_64.tar.gz").exit_code != 0 return false;
        array_add(*assets, "dist/fastcord-linux-x86_64.tar.gz");
    } else {
        log_error("release: build on macOS (the Mac app) or Windows (Windows and Linux)");
        return false;
    }
    for assets print("% (%)\n", it, version);
    return true;
}

PYTHON :: #run ifx OS == .WINDOWS then "python" else "python3";

// Runs a program with TZ=UTC (fixed clocks in fixtures), saving its output to log; true on exit 0. Leading
// NAME=value arguments are more environment variables.
run_logged :: (log: string, args: ..string) -> bool {
    a: [..]string;
    #if OS == .WINDOWS {
        // no env(1): set them here, children inherit them (every run sets the same values)
        kernel32 :: #system_library "kernel32";
        SetEnvironmentVariableA :: (name: *u8, value: *u8) -> s32 #foreign kernel32;
        SetEnvironmentVariableA("TZ", "UTC");
        for args {
            eq := find_index_from_left(it, #char "=");
            if a.count || eq <= 0 || it[0] == #char "-" { array_add(*a, it); continue; }
            SetEnvironmentVariableA(temp_c_string(slice(it, 0, eq)), temp_c_string(slice(it, eq + 1, it.count - eq - 1)));
        }
    } else {
        array_add(*a, "/usr/bin/env", "TZ=UTC");
        for args array_add(*a, it);
    }
    r, out, err := run_command(..a, capture_and_return_output = true);
    write_entire_file(log, join(out, err));
    return r.exit_code == 0;
}

// Every tests/ui script (chat fixture), tests/ui/rail (rail fixture) and tests/ui/dm (dm fixture) script and the dead-control sweep, as
// parallel headless processes; results print in a fixed order.
ui_scripts :: () -> bool {
    Job :: struct { name: string; args: [..]string; ok: bool; }
    jobs: [..]Job;
    BIN :: #run built("fastcord-dev");
    add :: (jobs: *[..]Job, name: string, fixture: string, script: string, env := "") {
        j := array_add(jobs);
        j.name = name;
        if env array_add(*j.args, env);
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
    for file_list("tests/ui/emoji") if ends_with(it, ".txt")
        add(*jobs, tprint("emoji_%", path_strip_extension(path_filename(it))), "tests/ui/chat_emoji.jsonl", it, "FASTCORD_MEDIA_DIR=tests/ui/emoji/media");
    for file_list("tests/ui/media") if ends_with(it, ".txt")  // GIFs, GIFV embeds and their menus, media served offline
        add(*jobs, tprint("media_%", path_strip_extension(path_filename(it))), "tests/ui/media/media.jsonl", it, "FASTCORD_MEDIA_DIR=tests/ui/media");
    for file_list("tests/ui/code") if ends_with(it, ".txt")  // ``` blocks in the highlighted languages
        add(*jobs, tprint("code_%", path_strip_extension(path_filename(it))), "tests/ui/code/code.jsonl", it);
    for file_list("tests/ui/call") if ends_with(it, ".txt")  // the call view (voice states in the General voice channel)
        add(*jobs, tprint("call_%", path_strip_extension(path_filename(it))), "tests/ui/call/call.jsonl", it);
    for file_list("tests/ui/forward") if ends_with(it, ".txt")  // quotes, a forward, unread messages after a read marker
        add(*jobs, tprint("forward_%", path_strip_extension(path_filename(it))), "tests/ui/chat_forward.jsonl", it);
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
        if run_command(PYTHON, "-I", "tests/bench/make_bench_fixture.py", "build/bench/heavy.jsonl").exit_code != 0 return false;
    file_delete("build/bench/latest.jsonl");
    for file_list("tests/bench") {
        if !ends_with(it, ".txt") continue;
        name := path_strip_extension(path_filename(it));
        if only && only != name continue;
        // account.txt starts at home like a fresh launch; the others open the bench channel
        a: [..]string;
        array_add(*a, "FASTCORD_MEDIA_DIR=build/bench/media", built("fastcord-dev"), "-dpi:1", "-now:1793016000",
            "-fixture:build/bench/heavy.jsonl", "-bench:build/bench/latest.jsonl", tprint("-prof:build/bench/%", name), tprint("-script:%", it));
        if name != "account" array_add(*a, "-channel:1600000000000100003");
        if !run_logged(tprint("build/bench/%.log", name), ..a) { print("FAIL % (see build/bench/%.log)\n", it, name); return false; }
    }
    ok := run_command(PYTHON, "-I", "tools/bench_compare.py", "build/bench/latest.jsonl", "--baseline", "build/bench/baseline.jsonl",
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
	<key>NSCameraUsageDescription</key><string>Fastcord uses the camera for video calls.</string>
	<key>LSApplicationCategoryType</key><string>public.app-category.social-networking</string>
</dict>
</plist>
XML

link :: (p: *Message_Phase, exe: string, cpu: CPU_Tag) -> bool {
    a: [..]string;
    if LINUX array_add(*a, ZIG, "c++", "-target", GLIBC, "-o", exe);
    // zig cc, not c++: the C++ links against the SDK's libc++ (-lc++ below), whose headers the C compiled with
    else array_add(*a, ZIG, "cc", "-target", ifx cpu == .X64 then "x86_64-macos.13.0" else "aarch64-macos.13.0",
        tprint("--sysroot=%", MAC_SDK), "-F", "/System/Library/Frameworks", "-L", "/usr/lib", "-o", exe); // zig prefixes -F and -L with the sysroot
    array_add(*a, ..p.compiler_generated_object_files);
    for p.support_object_files {
        // A native Linux build lists the system's C startup objects; zig links its own glibc 2.17 ones.
        name := path_filename(it);
        if LINUX && (begins_with(name, "crt") || name == "Scrt1.o") continue;
        array_add(*a, it);
    }
    for p.user_libraries array_add(*a, it);
    // Jai lists "-lX" and "-framework", "X" pairs (a cross-compile names them "X.dll"); drop duplicates.
    seen: [..]string;
    libs := p.system_libraries;
    for i: 0..libs.count-1 {
        if i > 0 && libs[i-1] == "-framework" continue;
        arg := ifx libs[i] == "-framework" then tprint("-framework %", libs[i+1]) else libs[i];
        if LINUX && !begins_with(arg, "-") {
            name := path_strip_extension(path_filename(arg));
            if begins_with(name, "lib") name = slice(name, 3, name.count - 3);
            if ends_with(name, ".so") name = slice(name, 0, name.count - 3);
            arg = tprint("-l%", name);
        }
        if array_find(seen, arg) continue;
        array_add(*seen, arg);
        if libs[i] == "-framework" array_add(*a, "-framework", libs[i+1]);
        else array_add(*a, arg);
    }
    if LINUX array_add(*a, "-ldl", "-lpthread", "-lm", "-static-libgcc");
    else array_add(*a, "-lc++");
    r := run_command(..a);
    return r.exit_code == 0;
}

// Every object that goes into the vendor archive.
vendor_outputs :: () -> [..]string {
    out: [..]string;
    for src: c_units() array_add(*out, obj_of(src));
    for list: source_lists() for file_list(list_dir(list)) if ends_with(it, ".o") array_add(*out, it);
    return out;
}
list_dir :: (list: string) -> string {
    name := path_strip_extension(path_filename(list));
    return tprint("%/%", OBJ(), slice(name, 3, name.count - 3));
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
// A vendor/<lib>/.linux file marks a library only the Linux build uses (FreeType, HarfBuzz).
vendor_dirs :: () -> [..]string {
    out: [..]string;
    visit_files("vendor", false, *out, (info: *File_Visit_Info, out: *[..]string) {
        if LINUX || !file_exists(tprint("%/.linux", info.full_name)) array_add(out, copy_string(info.full_name));
    }, visit_files = false, visit_directories = true);
    return out;
}
obj_of :: (src: string) -> string { return tprint("%/%.o", OBJ(), path_strip_extension(path_filename(src))); }

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

// The pinned Zig, downloaded once into build/zig and checked against ziglang.org's sha256.
ZIG_VERSION :: "0.17.0";
#if OS == .WINDOWS {
    ZIG_HOST :: "x86_64-windows"; ZIG_ARCHIVE :: "zip";    ZIG_SHA256 :: "b5663f69581dcf391293fbf16c06cb80d81d806545ce618b4d0bab7f0eb8c428";
} else #if OS == .MACOS && CPU == .ARM64 {
    ZIG_HOST :: "aarch64-macos";  ZIG_ARCHIVE :: "tar.xz"; ZIG_SHA256 :: "b607e9b9234790a008116ae5bdb71c6243b84b9fb42a53a9e70fde41c06c536a";
} else #if OS == .MACOS {
    ZIG_HOST :: "x86_64-macos";   ZIG_ARCHIVE :: "tar.xz"; ZIG_SHA256 :: "4f9a1c5269aa17ebda5e6d3c2b89d6cbf36f7d2b22a0306e9ab98f25f95529c6";
} else {
    ZIG_HOST :: "x86_64-linux";   ZIG_ARCHIVE :: "tar.xz"; ZIG_SHA256 :: "1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026";
}
ZIG_NAME :: #run tprint("zig-%-%", ZIG_HOST, ZIG_VERSION);
#if OS == .WINDOWS ZIG :: #run tprint("build\\zig\\%\\zig.exe", ZIG_NAME);  // CreateProcess wants backslashes
else               ZIG :: #run tprint("build/zig/%/zig", ZIG_NAME);

fetch_zig :: () -> bool {
    if file_exists(ZIG) return true;
    make_directory_if_it_does_not_exist("build/zig");
    archive := tprint("build/zig/%.%", ZIG_NAME, ZIG_ARCHIVE);
    print("downloading %\n", archive);
    if run_command("curl", "-fsSL", "-o", archive, tprint("https://ziglang.org/download/%/%.%", ZIG_VERSION, ZIG_NAME, ZIG_ARCHIVE)).exit_code != 0 return false;
    #if OS == .WINDOWS r, out := run_command("certutil", "-hashfile", archive, "SHA256", capture_and_return_output = true);
    else               r, out := run_command("shasum", "-a", "256", archive, capture_and_return_output = true);
    ok := r.exit_code == 0 && contains(to_lower_copy(out,, temp), ZIG_SHA256);
    if !ok log_error("% does not match sha256 %", archive, ZIG_SHA256);
    // tar unpacks the Windows zip too (bsdtar ships with Windows 10+).
    ok = ok && run_command("tar", "-xf", archive, "-C", "build/zig").exit_code == 0 && file_exists(ZIG);
    file_delete(archive);
    return ok;
}

// The C++ library headers come from the system the program links against, not zig's libc++ (which would need
// linking too): the MSVC STL on Windows, the SDK's libc++ on macOS.
MAC_SDK := "";

// Every C compile goes through zig cc.
cc :: (a: *[..]string, cpp: bool) {
    array_add(a, ZIG, ifx cpp then "c++" else "cc", "-c", "-O2");
    // the autoconf names the network libraries test for their byte-order headers
    if LINUX array_add(a, "-target", GLIBC, "-fPIC", "-DHAVE_ARPA_INET_H", "-DHAVE_NETINET_IN_H");
    else if OS == .WINDOWS {
        array_add(a, "-target", "x86_64-windows-msvc", "-D_CRT_SECURE_NO_WARNINGS", "-fms-runtime-lib=dll"); // the DLL CRT, as Jai links
        // Zig takes the newest VS's headers while Jai may link an older VS's msvcprt, which lacks the vectorized algorithm helpers.
        if cpp array_add(a, "-nostdinc++", "-D_USE_STD_VECTOR_ALGORITHMS=0");
    } else {
        array_add(a, "-target", tprint("%-macos.13.0", MAC_ARCH), tprint("--sysroot=%", MAC_SDK));
        // -I, not -isystem: zig puts a user -isystem after its own C headers, and libc++ must come first.
        if cpp array_add(a, "-nostdinc++", "-I", tprint("%/usr/include/c++/v1", MAC_SDK));
    }
    if cpp array_add(a, "-std=c++17", "-fno-exceptions", "-fno-rtti");
}

build_c :: () -> bool {
    if !fetch_zig() return false;
    #if OS == .MACOS if !LINUX {
        r, out := run_command("xcrun", "--show-sdk-path", capture_and_return_output = true);
        if r.exit_code != 0 return false;
        MAC_SDK = copy_string(trim(out));
        // Each Jai program links its arch's slice of the universal archive.
        for string.["aarch64", "x86_64"] { MAC_ARCH = it; if !build_c_target() return false; }
        MAC_ARCH = "";
        lib := VENDOR_LIB();
        arm, x64 := "build/mac-aarch64/fc_vendor.a", "build/mac-x86_64/fc_vendor.a";
        m, _, ok := file_modtime_and_size(lib);
        if ok && file_modtime_and_size(arm) <= m && file_modtime_and_size(x64) <= m return true;
        return run_command("lipo", "-create", arm, x64, "-output", lib).exit_code == 0;
    }
    return build_c_target();
}

build_c_target :: () -> bool {
    make_directory_if_it_does_not_exist(OBJ(), recursive = true);
    jobs: [..][..]string;
    stamps: [..]string;
    for src: c_units() {
        obj := obj_of(src);
        if !stale(obj, path_strip_filename(src)) continue;
        a: [..]string;
        cc(*a, false);
        array_add(*a, ..cflags(path_strip_extension(src)));
        array_add(*a, "-o", obj, src);
        array_add(*jobs, a);
    }
    for list: source_lists() {
        // a stamp marks the list's objects as current
        stamp := tprint("%.stamp", list_dir(list));
        if !stale(stamp, path_strip_filename(list)) continue;
        dir := list_dir(list);
        make_directory_if_it_does_not_exist(dir, recursive = true);
        text := read_entire_file(list);
        extra := cflags(path_strip_extension(list));
        for line: split(text, "\n") {
            f := trim(line);
            if !f continue;
            a: [..]string;
            cc(*a, !ends_with(f, ".c"));
            array_add(*a, ..extra);
            // per-file SIMD (libwebp and WebRTC pick them at run time; WebRTC's x86 files don't guard themselves)
            if MAC_ARCH != "aarch64" {
                if ends_with(f, "_sse41.c") array_add(*a, "-msse4.1");
                if ends_with(f, "_avx2.c") array_add(*a, "-mavx2");
                if ends_with(f, "_avx512.c") array_add(*a, "-mavx512f", "-mavx512vl");
                if ends_with(f, "_avx2.cc") array_add(*a, "-mavx2", "-mfma"); // as WebRTC's own build
                if ends_with(f, "_neon.cc") continue;
            } else if ends_with(f, "_avx2.cc") || ends_with(f, "_sse.cc") || ends_with(f, "_sse2.cc") continue;
            array_add(*a, "-o", tprint("%/%.o", dir, path_filename(f)), f);
            array_add(*jobs, a);
        }
        array_add(*stamps, stamp);
    }
    if !run_parallel(jobs) return false;
    for stamps write_entire_file(it, "");
    // One archive for the Jai side: every module's `#library,no_dll "../../build/fc_vendor"`.
    lib := VENDOR_LIB();
    m, _, ok := file_modtime_and_size(lib);
    need := !ok;
    objs := vendor_outputs();
    for objs { t := file_modtime_and_size(it); if t > m need = true; }
    if !need return true;
    file_delete(lib);
    // the object list goes in a response file: it is longer than a Windows command line
    rsp := tprint("%.rsp", lib);
    write_entire_file(rsp, join(..objs, "\n"));
    return run_command(ZIG, "ar", "rcs", lib, tprint("@%", rsp)).exit_code == 0;
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
