// jai build.jai - <target>: see USAGE below.
// Compiles the vendored C libraries (each vendor/<lib>/fc_<lib>.c, or the files listed in fc_<lib>.sources)
// into build/, then the Jai program, then links everything. The C, and the macOS and Linux links, go through pinned cross_cc v2 cached in build/cross_cc,
// but for the local builds (see HOST).
#import "Basic";
#import "Compiler";
#import "Process";
#import "File";
#import "File_Utilities";
#import "String";
#import "Thread";
#import "System";
#import "Sort";
#if OS == .WINDOWS { WR :: #import "Windows_Resources"; W :: #import "Windows"; }
AT :: #import "Android/Toolchain";

// Stallable: build() calls Basic procedures, like string_to_int, that hold #runs of their own. If the
// compiler reaches one before that #run has executed, a plain #run fails the build instead of waiting.
#run,stallable build();

build :: () {
    set_build_options_dc(.{do_output = false});
    args := get_build_options().compile_time_command_line;
    if args.count && args[args.count-1] == "linux" { LINUX = true; args.count -= 1; }
    target := ifx args.count then args[0] else "app";
    if target == "android" {
        ANDROID = true;
        for array_view(args, 1) {
            if it == "x64" ANDROID_CPU = .X64;
            if it == "debug" ANDROID_DEBUG = true;
        }
        if !android_paths() { compiler_set_workspace_status(.FAILED); return; }
    }
    HOST = !ANDROID && !array_find(string.["app", "release", "release_x64"], target) && (!LINUX || OS == .LINUX);
    make_directory_if_it_does_not_exist(OBJ(), recursive = true);
    if !build_c() { log_error("C build failed"); compiler_set_workspace_status(.FAILED); return; }
    APP :: "app :: #import \"app\"; main :: () { app.main(); }";
    ok := true;
    if target == {
        case "c";      return;
        case "app";    ok = compile("fastcord", APP, .VERY_OPTIMIZED, gui = true);
        case "dev";    ok = compile("fastcord-dev", APP, .OPTIMIZED);
        case "debug";  ok = compile("fastcord-debug", APP, .DEBUG);
        case "tool";   ok = compile(args[1], tprint("t :: #import \"tool_%\"; main :: () { t.main(); }", args[1]));  // a tool is a module with a main
        case "parity"; ok = compile("parity", file = "src/discord_parity/module.jai");
        case "run";    ok = compile(path_strip_extension(path_filename(args[1])), file = args[1]);
        case "fuzz";
            mem := args.count > 1 && args[1] == "mem";
            ui := args.count > 1 && args[1] == "ui"; // Links the whole app, so it has a binary of its own.
            ok = compile(ifx mem then "fuzz-mem" else ifx ui then "fuzz-ui" else "fuzz", tprint("MEM_DEBUG :: %; UI_TARGET :: %; #load \"src/tests/fuzz.jai\";", mem, ui), .OPTIMIZED, coverage = true) && fuzz(args, mem);
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
        case "android"; ok = android();
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
  fuzz <target> [seconds]     fuzz one target, `all` of them, or 0 seconds to replay; a failure is saved in tests/fuzz/<target>/
  fuzz mem <target> [seconds] the same with Basic's Memory_Debugger: double frees with stacks, leaks, poisoned temp
  fuzz ui [seconds]           the whole app headless and offline: hostile events on real fixtures, input on every view
  fuzz scale                  each text parser on repeated openers at two sizes; fails on superlinear time
  android [x64] [debug]       build/android/fastcord-<cpu>.apk (arm64 for phones, x64 for the emulator); needs ANDROID_HOME with an NDK; debug: unoptimised, faster to build
  release <vX.Y.Z>            dist/: the Mac app on macOS, Windows + Linux on Windows (CI publishes them)
  og                          site/og.jpg (link preview) from tools/og/card.html
  c                           only the vendored C libraries
  <target> linux              any target cross-compiled for x86_64 Linux (from Windows or macOS)
END

// A trailing "linux" argument (implied on a Linux host) builds everything for x86_64 Linux: the C with `cross_cc cc` against
// glibc 2.17 (so one binary runs on every distro since 2014), the Jai with os_target = .LINUX.
LINUX := OS == .LINUX;
GLIBC :: "x86_64-linux-gnu.2.17";
// Native macOS compiles the C once per arch ("aarch64", "x86_64") and joins the two archives with lipo.
MAC_ARCH := "";
// The android target builds the app for Android with the NDK's clang and Jai's Android toolchain.
ANDROID := false;
ANDROID_CPU := CPU_Tag.ARM64;
ANDROID_DEBUG := false;
// The C's minimum API level, the manifest's minSdkVersion. 33 (Android 13): Jai's Android toolchain links
// against API 34's stubs, and its Input module and backtrace need API 33's symbols.
ANDROID_MIN_API :: 33;
NDK_BIN := "";
NDK_EXE :: #run ifx OS == .WINDOWS then ".exe" else "";
OBJ :: () -> string {
    if ANDROID return tprint("build/android-%", android_arch());
    if HOST return "build/host";
    if LINUX return "build/linux";
    if MAC_ARCH return tprint("build/mac-%", MAC_ARCH);
    return "build";
}
// Every module links "build/fc_vendor", so the cross_cc, host and Linux builds share that path; its .target file
// names which one it holds, and a build for another remakes it.
vendor_lib_target :: () -> string {
    s, ok := read_entire_file(tprint("%.target", VENDOR_LIB()), log_errors = false);
    return ifx ok then s else "";
}
set_vendor_lib_target :: (target: string) -> bool { return write_entire_file(tprint("%.target", VENDOR_LIB()), target); }

VENDOR_LIB :: () -> string {
    #if OS == .WINDOWS if !LINUX && !ANDROID return "build/fc_vendor.lib";
    if MAC_ARCH && !HOST return tprint("%/fc_vendor.a", OBJ());
    return "build/fc_vendor.a";
}

// Local builds (dev, debug, tests, tools) compile the C with this machine's own compiler, for the quickest
// builds: MSVC's cl and lib on Windows (from the Visual Studio Jai links with), clang on macOS, cc on Linux,
// for the host's CPU only. What ships (app, release) and every cross-build for Linux use pinned cross_cc v2, so
// it is reproducible and built the same way from any host.
HOST := false;
MSVC :: () -> bool { return HOST && OS == .WINDOWS; }
MSVC_BIN := "";
// A program built into build/, as a path CreateProcess / exec take.
// fuzz runs build/fuzz on one target; when it dies, the input it was on joins tests/fuzz/<target>/ as a
// regression test (src/tests/fuzz.jai replays that directory first).
fuzz :: (args_in: []string, mem: bool) -> bool {
    args := args_in;
    if mem args = array_view(args, 1);
    exe := built(ifx mem then "fuzz-mem" else ifx args.count > 1 && args[1] == "ui" then "fuzz-ui" else "fuzz");
    if args.count < 2 { log_error("usage: fuzz [mem] <target>|all|scale [seconds]"); return false; }
    if args[1] == "scale" || args[1] == "list" return run_command(exe, args[1]).exit_code == 0;
    one :: (exe: string, target: string, seconds: string) -> bool {
        a: [..]string;
        array_add(*a, exe, target);
        if seconds array_add(*a, seconds);
        if run_command(..a).exit_code == 0 return true;
        data, ok := read_entire_file(tprint("build/fuzz_inputs/%.last", target));
        if !ok return false;
        dir := tprint("tests/fuzz/%", target);
        make_directory_if_it_does_not_exist(dir, recursive = true);
        saved := tprint("%/crash-%.bin", dir, to_milliseconds(current_time_consensus()));
        n := (cast(*s64) data.data).*;
        input := slice(data, 8, n); // src/tests/fuzz.jai's mapped file: its length, then the input.
        write_entire_file(saved, input);
        log_error("fuzz: the input that stopped the run is saved as %", saved);
        return false;
    }
    seconds := ifx args.count > 2 then args[2] else "";
    if args[1] != "all" return one(exe, args[1], seconds);
    result, list := run_command(exe, "list", capture_and_return_output = true);
    ok := true;
    for split(list, "\n") {
        target := trim(it);
        if target && !one(exe, target, seconds) ok = false;
    }
    return ok;
}

built :: (name: string) -> string { #if OS == .WINDOWS return join("build\\", name, ".exe",, temp); else return tprint("build/%", name); }

// cover counts every block of fastcord's own procedures into context.fuzz_cov (src/tests/fuzz.jai), and
// lists each block's place in build/<name>.blocks, a line per index. Procedures with no context are left out.
cover_next := 0;
cover_lines: String_Builder;
cover :: (m: *Message_Typechecked) {
    for * tc: m.procedure_bodies {
        body := tc.expression;
        if body.body_flags & .ALREADY_MODIFIED continue;
        h := body.header;
        if !h || !body.enclosing_load continue;
        if h.procedure_flags & (h.procedure_flags.POLYMORPHIC | .COMPILER_GENERATED | .COMPILE_TIME_ONLY | .QUICK | .TYPE_ONLY | .MACRO) continue;
        if (cast(*Type_Info_Procedure) h.type).procedure_flags & .HAS_NO_CONTEXT continue;
        path := body.enclosing_load.fully_pathed_filename;
        at := find_index_from_left(path, "/src/");
        if at < 0 continue;
        file := replace(slice(path, at + 1, path.count - at - 1), "tests/../", "",, temp); // A test's #load of app code.
        if begins_with(file, "src/tests/") continue;
        count := 0;
        add :: (block: *Code_Block) #expand {
            // A macro's body is its own file's, and an ifx arm is an expression: neither takes a statement.
            if !block || block.block_type != .IMPERATIVE || (block.enclosing_load && block.enclosing_load != body.enclosing_load) return;
            if block.statements.count && block.statements[0].kind == .DIRECTIVE_INSERT return;
            literal := make_string_literal(sprint("if context.fuzz_cov context.fuzz_cov[%] += 1;", cover_next));
            insert := New(Code_Directive_Insert);
            insert.kind = .DIRECTIVE_INSERT;
            insert.expression = literal;
            insert.location = block.location;
            statements := NewArray(block.statements.count + 1, *Code_Node);
            statements[0] = insert;
            memcpy(statements.data + 1, block.statements.data, block.statements.count * size_of(*Code_Node));
            block.statements = statements;
            print_to_builder(*cover_lines, "%:% %\n", file, block.l0, h.name);
            cover_next += 1;
            `count += 1;
        }
        // `if x return;` has a block too, which the flat list leaves out.
        for tc.subexpressions {
            if it.kind == {
                case .BLOCK; add(cast(*Code_Block) it);
                case .CASE;  add((cast(*Code_Case) it).then_block);
                case .WHILE; add((cast(*Code_While) it).block);
                case .FOR;   add((cast(*Code_For) it).block);
                case .IF;
                    c := cast(*Code_If) it;
                    if c.if_flags & (.IS_IFX | .IS_STATIC | .IS_SWITCH_STATEMENT) continue;
                    add(c.then_block);
                    add(c.else_block);
            }
        }
        if count compiler_modify_procedure(m.workspace, body);
    }
}

// compile builds one program into build/<name>: the root is a file or a build string.
compile :: (name: string, source := "", optimization := Optimization_Type.DEBUG, file := "", cpu := CPU, gui := false, coverage := false) -> bool {
    w := compiler_create_workspace(name);
    o := get_build_options(w);
    import_path: [..]string;
    array_add(*import_path, "src");
    for o.import_path array_add(*import_path, it);
    o.import_path = import_path;
    if LINUX o.os_target = .LINUX;
    // Windows links with the compiler's own linker step (MSVC libraries); macOS and Linux with cross_cc
    o.use_custom_link_command = OS != .WINDOWS || LINUX || ANDROID;
    o.text_output_flags = 0;
    if ANDROID o.text_output_flags = .OUTPUT_TIMING_INFO;
    o.output_executable_name = name;
    o.output_path = "build";
    o.cpu_target = cpu;
    set_optimization(*o, optimization);   // first: it resets the checks below
    // set_optimization turns split modules off for inlining, leaving LLVM one thread: dev builds 87 s -> 19 s,
    // bench latency unchanged, UI pass ~25% slower than unsplit
    if optimization == .OPTIMIZED o.llvm_options.enable_split_modules = true;
    if ANDROID {
        o.os_target = .ANDROID;
        o.cpu_target = ANDROID_CPU;
        o.output_type = .DYNAMIC_LIBRARY;
        o.backend = .LLVM;
        _, o.llvm_options.target_system_triple = AT.get_android_target_triple(ANDROID_CPU);
        if ANDROID_CPU == .ARM64 o.llvm_options.target_system_features = "+lse"; // ARMv8.1 atomics, as Jai's toolchain assumes
        o.output_path = android_lib_dir();
        make_directory_if_it_does_not_exist(o.output_path, recursive = true);
    }
    // `- module` and debug type-check every procedure, not only the ones called; dev and shipping drop the dead ones
    // (Android keeps it: Jai's Socket has a procedure that doesn't compile for Android.)
    if optimization == .DEBUG && !ANDROID o.dead_code_elimination = .NONE;
    o.cast_bounds_check = .OFF;      // integer casts truncate, as the wire encoders expect
    // An out-of-bounds index or null dereference stops the program instead of corrupting memory, in every
    // build: fastcord parses what any server and any user send. Loops the bench shows are hot take #no_abc.
    o.array_bounds_check = .ON;
    o.null_pointer_check = .ON;
    set_build_options(o, w);
    // a release exe opens no console window (Windows only; dev builds keep printing to it)
    #if OS == .WINDOWS if gui && !LINUX WR.disable_runtime_console(w);
    compiler_begin_intercept(w);
    if file add_build_file(file, w); else add_build_string(source, w);
    ok := true;
    while true {
        m := compiler_wait_for_message();
        if m.kind == .ERROR ok = false;
        if m.kind == .COMPLETE { if (cast(*Message_Complete) m).error_code != .NONE ok = false; break; }
        if coverage && m.kind == .TYPECHECKED cover(cast(*Message_Typechecked) m);
        if m.kind == .PHASE {
            p := cast(*Message_Phase) m;
            if p.phase == .READY_FOR_CUSTOM_LINK_COMMAND {
                if ANDROID AT.run_android_link_command(p, o, android_link_args()); // reports its own failure and completion
                else {
                    if !link(p, tprint("build/%", name), cpu) ok = false;
                    compiler_custom_link_command_is_complete(w);
                }
            }
        }
    }
    compiler_end_intercept(w);
    if coverage write_entire_file(tprint("build/%.blocks", name), builder_to_string(*cover_lines));
    // Every Windows build of the app gets the icon; the window loads it from the exe as resource 2. Right
    // after the link the exe can still be held open (EndUpdateResource fails with error 110), so retry.
    #if OS == .WINDOWS if ok && !LINUX && !ANDROID && begins_with(source, "app :: #import \"app\"") {
        for 1..30 {
            ok = WR.set_icon_by_filename(tprint("build/%.exe", name), "assets/fastcord.ico");
            if ok break;
            sleep_milliseconds(200);
        }
    }
    return ok;
}

// android [x64]: build/android/fastcord-<cpu>.apk, the app as a NativeActivity library (libfastcord.so),
// optimised with symbols like dev. Jai's toolchain writes, signs and zips the APK itself (no Gradle, no Java);
// it signs with a debug key it makes once in build/android/.build_android.
android :: () -> bool {
    root :: "app :: #import \"app\"; platform :: #import \"platform\"; main :: () { platform.stdio_to_logcat(); app.main(); } #import \"Android\"()(main);";
    start := current_time_monotonic();
    if !compile("fastcord", root, ifx ANDROID_DEBUG then .DEBUG else .OPTIMIZED) return false;
    built := current_time_monotonic();
    config: AT.Android_Project_Config;
    config.app_name = "Fastcord";
    config.app_id = "com.creikey.fastcord"; // @Todo: Settle the id before a release; changing it later loses users' data.
    config.lib_name = "fastcord";
    config.min_sdk_level = ANDROID_MIN_API;
    config.permissions = .["android.permission.INTERNET"];
    options: AT.Android_Build_Options;
    options.mode = .ILL_WRITE_IT_AND_WELL_DO_IT_LIVE_FUCKING_THING_SUCKS;
    options.cpu_target = ANDROID_CPU;
    options.intermediate_path = "build/android/.build_android";
    options.output_path = "build/android";
    options.output_apk_name = tprint("fastcord-%", android_arch());
    options.shared_library_path = android_lib_dir();
    ok, apk := AT.android_generate_apk(options, config);
    if ok print("apk: % (C and app %s, APK %s)\n", apk, to_float64_seconds(built - start), to_float64_seconds(current_time_monotonic() - built));
    return ok;
}

android_arch :: () -> string { return ifx ANDROID_CPU == .ARM64 then "aarch64" else "x86_64"; }
android_lib_dir :: () -> string { return tprint("build/android/lib/%", AT.get_android_project_jni_architecture_name(ANDROID_CPU)); }

// The NDK's clang, from ANDROID_NDK_HOME or the newest NDK under ANDROID_HOME.
android_paths :: () -> bool {
    ok, ndk := AT.android_find_ndk_path(log_errors = true);
    if !ok { log_error("android: set ANDROID_HOME to an Android SDK with an NDK (sdk/ndk/<version>)"); return false; }
    host :: #run ifx OS == .WINDOWS then "windows-x86_64" else ifx OS == .MACOS then "darwin-x86_64" else "linux-x86_64";
    NDK_BIN = sprint("%/toolchains/llvm/prebuilt/%/bin", ndk, host);
    if !file_exists(join(NDK_BIN, "/clang", NDK_EXE,, temp)) { log_error("android: no clang in %", NDK_BIN); return false; }
    return true;
}

// The NDK's C++ library and compiler runtime, which the vendored C++ and clang's helpers need: the app links
// with ld.lld directly, so nothing adds them for it.
android_link_args :: () -> []string {
    triple := tprint("%-linux-android", android_arch());
    toolchain := path_strip_filename(NDK_BIN);
    a: [..]string;
    array_add(*a, tprint("-L%sysroot/usr/lib/%", toolchain, triple), "-lc++_static", "-lc++abi", "--no-undefined");
    for file_list(tprint("%lib/clang", toolchain), recursive = true) {
        if path_filename(it) == tprint("libclang_rt.builtins-%-android.a", android_arch()) { array_add(*a, it); break; }
    }
    return a;
}

// release <vX.Y.Z>: the release archives this machine can build: on macOS dist/fastcord-macos.zip, a
// universal (arm64 + x86_64) ad-hoc signed Fastcord.app; on Windows dist/fastcord-windows.zip (Fastcord.exe)
// and dist/fastcord-linux-x86_64.tar.gz (cross-compiled), with the same Linux binary as the headless
// dist/fastcord-server-linux-x86_64.tar.gz. CI's release workflow uploads them.
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
        // The same binary for a headless machine: -serve runs before any display library is opened
        if run_command(PYTHON, "-I", "tools/package_linux.py", "build/fastcord-linux.stripped", "dist/fastcord-server-linux-x86_64.tar.gz", "server").exit_code != 0 return false;
        array_add(*assets, "dist/fastcord-server-linux-x86_64.tar.gz");
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
    for file_list("tests/ui") if ends_with(it, ".txt") && !ends_with(it, "sweep.txt") && !ends_with(it, "sweep_allow.txt") {
        own := tprint("%.jsonl", path_strip_extension(it));  // a script's own fixture, else the chat one
        add(*jobs, path_strip_extension(path_filename(it)), ifx file_exists(own) then own else "tests/ui/chat.jsonl", it);
    }
    for file_list("tests/ui/rail") if ends_with(it, ".txt")
        add(*jobs, tprint("rail_%", path_strip_extension(path_filename(it))), "tests/ui/rail.jsonl", it);
    for file_list("tests/ui/dm") if ends_with(it, ".txt")
        add(*jobs, tprint("dm_%", path_strip_extension(path_filename(it))), "tests/ui/dm.jsonl", it);
    // emoji scripts: the emoji fixture, with the Twemoji svgs they show served offline
    for file_list("tests/ui/emoji") if ends_with(it, ".txt")
        add(*jobs, tprint("emoji_%", path_strip_extension(path_filename(it))), "tests/ui/chat_emoji.jsonl", it, "FASTCORD_MEDIA_DIR=tests/ui/emoji/media");
    for file_list("tests/ui/media") if ends_with(it, ".txt") {  // GIFs, GIFV embeds and their menus, media served offline
        own := tprint("%.jsonl", path_strip_extension(it));
        add(*jobs, tprint("media_%", path_strip_extension(path_filename(it))), ifx file_exists(own) then own else "tests/ui/media/media.jsonl", it, "FASTCORD_MEDIA_DIR=tests/ui/media");
    }
    for file_list("tests/ui/code") if ends_with(it, ".txt")  // ``` blocks in the highlighted languages
        add(*jobs, tprint("code_%", path_strip_extension(path_filename(it))), "tests/ui/code/code.jsonl", it);
    for file_list("tests/ui/call") if ends_with(it, ".txt")  // the call view (voice states in the General voice channel)
        add(*jobs, tprint("call_%", path_strip_extension(path_filename(it))), "tests/ui/call/call.jsonl", it);
    for file_list("tests/ui/forward") if ends_with(it, ".txt")  // quotes, a forward, unread messages after a read marker
        add(*jobs, tprint("forward_%", path_strip_extension(path_filename(it))), "tests/ui/chat_forward.jsonl", it);
    for file_list("tests/ui/threads") if ends_with(it, ".txt")  // a thread, a forum with tags
        add(*jobs, tprint("threads_%", path_strip_extension(path_filename(it))), "tests/ui/chat_threads.jsonl", it);
    sweep := array_add(*jobs);
    sweep.name = "sweep";
    array_add(*sweep.args, BIN, "-shot:build/sweep.png", "-dpi:1", "-now:1793016000", "-sweep:tests/ui/sweep.txt");
    make_directory_if_it_does_not_exist("build/uires");
    // A few processes at a time: starting all 300-odd at once runs a 16 GB laptop out of memory.
    WORKERS :: 4;
    Pool :: struct { jobs: []Job; next: s64; mutex: Mutex; }
    pool: Pool;
    pool.jobs = jobs;
    init(*pool.mutex);
    threads: [WORKERS] Thread;
    for * threads {
        thread_init(it, (t: *Thread) -> s64 {
            pool := cast(*Pool) t.data;
            while true {
                lock(*pool.mutex);
                i := pool.next;
                pool.next += 1;
                unlock(*pool.mutex);
                if i >= pool.jobs.count break;
                j := *pool.jobs[i];
                j.ok = run_logged(tprint("build/uires/%.log", j.name), ..j.args);
            }
            return 0;
        });
        it.data = *pool;
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
	<key>CFBundleURLTypes</key><array>
		<dict><key>CFBundleURLName</key><string>fastcord invite</string><key>CFBundleURLSchemes</key><array><string>fc</string></array></dict>
		<dict><key>CFBundleURLName</key><string>Discord link</string><key>CFBundleURLSchemes</key><array><string>discord</string></array></dict>
	</array>
</dict>
</plist>
XML

link :: (p: *Message_Phase, exe: string, cpu: CPU_Tag) -> bool {
    a: [..]string;
    if HOST && LINUX array_add(*a, "c++", "-no-pie", "-o", exe);  // the Jai object is not position independent, and distros' gcc defaults to PIE
    else if HOST array_add(*a, "clang", "-arch", ifx cpu == .X64 then "x86_64" else "arm64", "-mmacosx-version-min=13.0", "-o", exe);
    else if LINUX array_add(*a, CROSS, "c++", "-target", GLIBC, "-o", exe);
    // cross_cc cc, not c++: the C++ links against the SDK's libc++ (-lc++ below), whose headers the C compiled with
    else array_add(*a, CROSS, "cc", "-target", ifx cpu == .X64 then "x86_64-macos.13.0" else "aarch64-macos.13.0",
        tprint("--sysroot=%", MAC_SDK), "-F", tprint("%/System/Library/Frameworks", MAC_SDK), "-L", tprint("%/usr/lib", MAC_SDK), "-o", exe);
    array_add(*a, ..p.compiler_generated_object_files);
    for p.support_object_files {
        if !it continue; // jai-linux can list empty paths, which the driver refuses
        // A native Linux build lists the system's C startup objects; cross_cc, and the host's driver, link their own.
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
    else array_add(*a, ifx HOST then "-lc++" else tprint("%/usr/lib/libc++.tbd", MAC_SDK)); // Link the SDK libc++ directly, not cross_cc's bundled runtime.
    r := run_command(..a);
    return r.exit_code == 0;
}

// Every object that goes into the vendor archive, or with `shared` ("vendor/<lib>/", one with a .shared file)
// into that library's own shared library.
vendor_outputs :: (shared := "") -> [..]string {
    mine :: (file: string, shared: string) -> bool {
        dir := path_strip_filename(file);
        return ifx shared then dir == shared else !file_exists(tprint("%.shared", dir));
    }
    out: [..]string;
    for src: c_units() if mine(src, shared) array_add(*out, obj_of(src));
    for list: source_lists() if mine(list, shared) for file_list(list_dir(list)) if ends_with(it, ".o") array_add(*out, it);
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
// A vendor/<lib>/.linux file marks a library only the Linux and Android builds use (FreeType, HarfBuzz).
vendor_dirs :: () -> [..]string {
    out: [..]string;
    visit_files("vendor", false, *out, (info: *File_Visit_Info, out: *[..]string) {
        if LINUX || ANDROID || !file_exists(tprint("%/.linux", info.full_name)) array_add(out, copy_string(info.full_name));
    }, visit_files = false, visit_directories = true);
    return out;
}
obj_of :: (src: string) -> string { return tprint("%/%.o", OBJ(), path_strip_extension(path_filename(src))); }

// Newest modification time under a directory, to decide what to rebuild. Edits to this file don't count:
// build_c_target compares the compile commands themselves, so only a change to a library's flags rebuilds it.
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
    s := read_entire_file(tprint("%.cflags", base), log_errors = false);
    // fc_<lib>.msvc.cflags adds what only cl needs
    if MSVC() s = tprint("% %", s, read_entire_file(tprint("%.msvc.cflags", base), log_errors = false));
    flags := break_command_into_strings(trim(s));
    for * flags it.* = patched(it.*);
    if !MSVC() return flags;
    // The .cflags files are clang's syntax. cl takes -I, -D and -w as they are; cc sets its own standard.
    out: [..]string;
    for flags {
        if begins_with(it, "-W") || begins_with(it, "-std=") || it == "-pthread" || it == "-include" || it == "-fexceptions" continue;
        // cl resolves a forced include against the include path, not the working directory
        if it_index > 0 && flags[it_index - 1] == "-include" array_add(*out, tprint("/FI%/%", get_working_directory(), it));
        else array_add(*out, it);
    }
    return out;
}

// The complete cross_cc v2 release for this host, verified before extraction.
CROSS_VERSION :: "v2";
#if OS == .WINDOWS {
    CROSS_HOST :: "windows-amd64"; CROSS_SHA256 :: "9320ddb34cb6c926561b5527d8f0eb4519b2b370f5b18c60822fd4bbf15c7262";
} else #if OS == .MACOS && CPU == .ARM64 {
    CROSS_HOST :: "darwin-arm64"; CROSS_SHA256 :: "64086d0cea2b4efeaf0564a2488798140445fa26f0dea1bd4a4441a43e662c99";
} else #if OS == .MACOS {
    CROSS_HOST :: "darwin-amd64"; CROSS_SHA256 :: "9a8e0bdad60d977b4cf02ae3623410e1a5b583c1eba32715dc6ad4dabfbaec6e";
} else {
    CROSS_HOST :: "linux-amd64"; CROSS_SHA256 :: "33076163d525a199c46235d6d7504cd39415047f4afdfbbcdbe8b9818076803a";
}
CROSS_DIR :: #run tprint("build/cross_cc/%", CROSS_VERSION);
CROSS_NAME :: #run tprint("cross_cc-%", CROSS_HOST);
CROSS_LIBC :: #run tprint("%/libc.txt", CROSS_DIR); // Windows: the same Visual Studio and SDK as Jai.
#if OS == .WINDOWS CROSS :: #run tprint("build\\cross_cc\\%\\%\\cross_cc.exe", CROSS_VERSION, CROSS_NAME);
else               CROSS :: #run tprint("%/%/cross_cc", CROSS_DIR, CROSS_NAME);

// BoringSSL's Windows assembly is NASM source: the pinned NASM, its sha256 taken at pinning (nasm.us
// publishes none).
NASM_VERSION :: "3.01";
NASM_SHA256 :: "e0ba5157007abc7b1a65118a96657a961ddf55f7e3f632ee035366dfce039ca4";
NASM :: #run tprint("build\\nasm\\nasm-%\\nasm.exe", NASM_VERSION);

// fetch downloads a pinned tool's archive once into dir, checks its sha256 and unpacks it.
fetch :: (exe: string, dir: string, url: string, sha256: string) -> bool {
    if file_exists(exe) return true;
    make_directory_if_it_does_not_exist(dir, recursive = true);
    archive := tprint("%/%", dir, path_filename(url));
    print("downloading %\n", archive);
    if run_command("curl", "-fsSL", "-o", archive, url).exit_code != 0 return false;
    #if OS == .WINDOWS r, out := run_command("certutil", "-hashfile", archive, "SHA256", capture_and_return_output = true);
    else #if OS == .LINUX r, out := run_command("sha256sum", archive, capture_and_return_output = true);  // coreutils; not every distro has Perl's shasum
    else               r, out := run_command("shasum", "-a", "256", archive, capture_and_return_output = true);
    ok := r.exit_code == 0 && contains(to_lower_copy(out,, temp), sha256);
    if !ok log_error("% does not match sha256 %", archive, sha256);
    // Linux GNU tar cannot read ZIPs; Windows and macOS ship bsdtar.
    #if OS == .LINUX ok = ok && run_command("unzip", "-q", "-o", archive, "-d", dir).exit_code == 0 && file_exists(exe);
    else ok = ok && run_command("tar", "-xf", archive, "-C", dir).exit_code == 0 && file_exists(exe);
    file_delete(archive);
    return ok;
}

// The C++ library headers come from the system the program links against, not cross_cc's bundled libc++ (which would need
// linking too): the MSVC STL on Windows, the SDK's libc++ on macOS.
MAC_SDK := "";

// Every non-host C compile goes through cross_cc cc.
cc :: (a: *[..]string, cpp: bool) {
    if MSVC() {
        array_add(a, tprint("%\\cl.exe", MSVC_BIN), "/nologo", "/c", "/O2", "/MD", "/utf-8", "/Zc:preprocessor", "/D_CRT_SECURE_NO_WARNINGS"); // /MD: the DLL CRT, as Jai links
        if cpp array_add(a, "/std:c++17", "/EHs-c-", "/GR-", "/D_HAS_EXCEPTIONS=0");
        else array_add(a, "/std:c17");
        return;
    }
    if ANDROID {
        // No outline atomics: the app links with ld.lld directly, not through clang, which would add the
        // __aarch64_* helpers they call.
        array_add(a, join(NDK_BIN, "/", ifx cpp then "clang++" else "clang", NDK_EXE,, temp), tprint("--target=%-linux-android%", android_arch(), ANDROID_MIN_API),
            "-c", "-O2", "-fPIC", "-DHAVE_ARPA_INET_H", "-DHAVE_NETINET_IN_H");
        if ANDROID_CPU == .ARM64 array_add(a, "-mno-outline-atomics");
        if cpp array_add(a, "-std=c++17", "-fno-exceptions", "-fno-rtti");
        return;
    }
    if HOST {
        if LINUX array_add(a, ifx cpp then "c++" else "cc", "-c", "-O2", "-fPIC", "-DHAVE_ARPA_INET_H", "-DHAVE_NETINET_IN_H");
        else array_add(a, "clang", "-c", "-O2", "-arch", ifx MAC_ARCH == "aarch64" then "arm64" else "x86_64", "-mmacosx-version-min=13.0");
        if cpp array_add(a, "-std=c++17", "-fno-exceptions", "-fno-rtti");
        return;
    }
    array_add(a, CROSS, ifx cpp then "c++" else "cc", "-c", "-O2");
    // the autoconf names the network libraries test for their byte-order headers
    if LINUX array_add(a, "-target", GLIBC, "-fPIC", "-DHAVE_ARPA_INET_H", "-DHAVE_NETINET_IN_H");
    else if OS == .WINDOWS {
        array_add(a, "-target", "x86_64-windows-msvc", "--libc", CROSS_LIBC, "-D_CRT_SECURE_NO_WARNINGS", "-fms-runtime-lib=dll"); // the DLL CRT, as Jai links
        // No vectorized algorithm helpers: the objects stay linkable against an older VS's msvcprt.
        if cpp array_add(a, "-nostdinc++", "-D_USE_STD_VECTOR_ALGORITHMS=0");
    } else {
        array_add(a, "-target", tprint("%-macos.13.0", MAC_ARCH), tprint("--sysroot=%", MAC_SDK));
        // The SDK libc++ headers must precede the bundled C headers.
        if cpp array_add(a, "-nostdinc++", "-I", tprint("%/usr/include/c++/v1", MAC_SDK));
    }
    if cpp array_add(a, "-std=c++17", "-fno-exceptions", "-fno-rtti");
}
// cc_out names a compile's object file.
cc_out :: (a: *[..]string, obj: string) {
    if MSVC() array_add(a, tprint("/Fo%", obj));
    else array_add(a, "-o", obj);
}

build_c :: () -> bool {
    if ANDROID return build_c_target();
    if !HOST && !fetch(CROSS, CROSS_DIR, tprint("https://github.com/SamHSmith/cross_cc/releases/download/%/cross_cc-%-%.zip", CROSS_VERSION, CROSS_VERSION, CROSS_HOST), CROSS_SHA256) return false;
    #if OS == .WINDOWS if !LINUX && !MSVC_BIN {
        lib, bin := WR.find_visual_studio_in_a_ridiculous_garbage_way();
        kit := WR.find_windows_kit_root();
        if !bin || !kit { log_error("build: install the Visual Studio Build Tools with the C++ tools"); return false; }
        MSVC_BIN = copy_string(bin);
        sdk := replace(kit, "Lib", "Include");
        if MSVC() {
            // The system headers go in INCLUDE, as vcvars sets it: cl searches it after every /I, so a library's
            // own header of the same name wins (dav1d's stdatomic.h for MSVC over MSVC's, which needs a flag).
            include := tprint("%\\..\\..\\include;%\\ucrt;%\\um;%\\shared", lib, sdk, sdk, sdk);
            W.SetEnvironmentVariableA("INCLUDE", to_c_string(include,, temp));
        } else {
            // Use Jai's Visual Studio and SDK, not independently discovered or downloaded MSVC.
            // Mixing VS versions can introduce STL calls missing from the runtime Jai links.
            libc := tprint("include_dir=%\\ucrt\nsys_include_dir=%\\..\\..\\include\ncrt_dir=%\\ucrt\\x64\nmsvc_lib_dir=%\nkernel32_lib_dir=%\\um\\x64\ncc_dir=\ndarwin_sdk_dir=\n",
                sdk, lib, kit, lib, kit);
            if !write_entire_file(CROSS_LIBC, libc) return false;
        }
    }
    #if OS == .WINDOWS if !LINUX && !fetch(NASM, "build/nasm", tprint("https://www.nasm.us/pub/nasm/releasebuilds/%/win64/nasm-%-win64.zip", NASM_VERSION, NASM_VERSION), NASM_SHA256) return false;
    #if OS == .MACOS if HOST {
        MAC_ARCH = ifx CPU == .ARM64 then "aarch64" else "x86_64";
        defer MAC_ARCH = "";
        return build_c_target();
    } else if !LINUX {
        r, out := run_command("xcrun", "--show-sdk-path", capture_and_return_output = true);
        if r.exit_code != 0 return false;
        MAC_SDK = copy_string(trim(out));
        // cross_cc's linker (LLD 22) cannot read the library stubs of newer SDKs (Xcode 27's name an arm64e.x1
        // arch) and leaves libc undefined: take the Command Line Tools' SDK then, if it can read that one.
        if !mac_sdk_readable(MAC_SDK) {
            clt :: "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk";
            if !mac_sdk_readable(clt) { log_error("build: % is too new for cross_cc's linker; install an older SDK (Xcode 26 or its Command Line Tools)", MAC_SDK); return false; }
            MAC_SDK = clt;
        }
        // Each Jai program links its arch's slice of the universal archive.
        for string.["aarch64", "x86_64"] { MAC_ARCH = it; if !build_c_target() return false; }
        MAC_ARCH = "";
        lib := VENDOR_LIB();
        arm, x64 := "build/mac-aarch64/fc_vendor.a", "build/mac-x86_64/fc_vendor.a";
        m, _, ok := file_modtime_and_size(lib);
        if ok && vendor_lib_target() == "mac" && file_modtime_and_size(arm) <= m && file_modtime_and_size(x64) <= m return true;
        file_delete(lib);
        if run_command("lipo", "-create", arm, x64, "-output", lib).exit_code != 0 return false;
        return set_vendor_lib_target("mac");
    }
    return build_c_target();
}

mac_sdk_readable :: (sdk: string) -> bool {
    stubs, ok := read_entire_file(tprint("%/usr/lib/libSystem.tbd", sdk), log_errors = false);
    return ok && !contains(stubs, "arm64e.x1");
}

// A library with vendor/<lib>/patches/*.patch builds from build/patched/<lib>: a copy of vendor/<lib> with
// the patches applied in name order by `git apply`, redone when anything under vendor/<lib> changes. Its
// sources list and .cflags keep naming vendor/<lib>; `patched` points them at the copy.
PATCHED: [..]string;
apply_patches :: () -> bool {
    array_reset(*PATCHED);
    for dir: vendor_dirs() {
        if !file_exists(tprint("%/patches", dir)) continue;
        patches := file_list(tprint("%/patches", dir));
        array_add(*PATCHED, dir);
        dst := tprint("build/patched/%", path_filename(dir));
        stamp := tprint("%.stamp", dst);
        if !stale(stamp, dir) continue;
        if file_exists(dst) && !delete_directory(dst) return false;
        for file_list(dir, recursive = true) {
            to := tprint("%/%", dst, slice(it, dir.count + 1, it.count - dir.count - 1));
            make_directory_if_it_does_not_exist(path_strip_filename(to), recursive = true);
            if !copy_file(it, to) return false;
        }
        quick_sort(patches, compare);
        for patches if run_command("git", "apply", tprint("--directory=%", dst), it).exit_code != 0 return false;
        write_entire_file(stamp, "");
    }
    return true;
}
patched :: (path: string) -> string {
    if begins_with(path, "-I") return tprint("-I%", patched(slice(path, 2, path.count - 2)));
    for PATCHED if begins_with(path, tprint("%/", it)) return tprint("build/patched/%", slice(path, it.count - path_filename(it).count, path.count));
    return path;
}

build_c_target :: () -> bool {
    make_directory_if_it_does_not_exist(OBJ(), recursive = true);
    if !apply_patches() return false;
    jobs: [..][..]string;
    // Each file holds the commands that built its objects, written once they all compiled: objects are
    // current while their sources are older and the commands are unchanged.
    stamps: [..]struct { path: string; commands: string; };
    same :: (path: string, commands: string) -> bool {
        text, ok := read_entire_file(path, log_errors = false);
        return ok && text == commands;
    }
    for src: c_units() {
        obj := obj_of(src);
        a: [..]string;
        cc(*a, false);
        array_add(*a, ..cflags(path_strip_extension(src)));
        cc_out(*a, obj);
        array_add(*a, src);
        command := join(..a, " ");
        cmd := tprint("%.cmd", obj);
        if !stale(obj, path_strip_filename(src)) && same(cmd, command) continue;
        array_add(*jobs, a);
        array_add(*stamps, .{cmd, command});
    }
    for list: source_lists() {
        stamp := tprint("%.stamp", list_dir(list));
        dir := list_dir(list);
        list_jobs: [..][..]string;
        text := read_entire_file(list);
        extra := cflags(path_strip_extension(list));
        for line: split(text, "\n") {
            // A line may start with a tag: "x86 " or "arm " builds the file only for that CPU, and "simd "
            // builds it for every CPU, with x86-64-v3 (AVX2, FMA, F16C, BMI2) on x86. Code built that way
            // is only reached after its library's own CPU check (ggml's, behind fc_stt_cpu_ok).
            f := trim(line);
            tag := "";
            for string.["x86 ", "arm ", "simd "] if begins_with(f, it) { tag = trim(it); f = trim(advance(f, it.count)); }
            arm := MAC_ARCH == "aarch64" || (ANDROID && ANDROID_CPU == .ARM64);
            if (tag == "x86" && arm) || (tag == "arm" && !arm) continue;
            f = patched(f);
            if !f continue;
            a: [..]string;
            // assembly guards itself by OS and CPU, so every file is built and the others come out empty
            if ends_with(f, ".asm") {
                #if OS != .WINDOWS continue;
                if LINUX || ANDROID continue;
                array_add(*a, NASM, "-f", "win64", "-o", tprint("%/%.o", dir, path_filename(f)), f);
                array_add(*list_jobs, a);
                continue;
            }
            // BoringSSL's .S files are its macOS and Linux assembly, which cl cannot read; Windows assembles the .asm
            if MSVC() && ends_with(f, ".S") continue;
            cc(*a, !ends_with(f, ".c") && !ends_with(f, ".S"));
            array_add(*a, ..extra);
            if (tag == "x86" || tag == "simd") && !arm {
                // cl's /arch:AVX2 also allows FMA, F16C and BMI2, and ggml defines their macros for it.
                if MSVC() array_add(*a, "/arch:AVX2");
                else array_add(*a, "-mavx2", "-mfma", "-mf16c", "-mbmi2");
                array_add(*a, "-DGGML_AVX", "-DGGML_AVX2", "-DGGML_FMA", "-DGGML_F16C", "-DGGML_BMI2", "-DGGML_SSE42");
            }
            // per-file SIMD (libwebp and WebRTC pick them at run time; WebRTC's x86 files don't guard themselves).
            // cl has the SSE4.1 intrinsics without a flag.
            if MSVC() {
                if ends_with(f, "_avx2.c") || ends_with(f, "_avx2.cc") array_add(*a, "/arch:AVX2");
                if ends_with(f, "_avx512.c") array_add(*a, "/arch:AVX512");
                if ends_with(f, "_neon.cc") continue;
            } else if !arm {
                if ends_with(f, "_sse41.c") array_add(*a, "-msse4.1");
                if ends_with(f, "_avx2.c") array_add(*a, "-mavx2");
                if ends_with(f, "_avx512.c") array_add(*a, "-mavx512f", "-mavx512vl");
                if ends_with(f, "_avx2.cc") array_add(*a, "-mavx2", "-mfma"); // as WebRTC's own build
                if ends_with(f, "_neon.cc") continue;
            } else if ends_with(f, "_avx2.cc") || ends_with(f, "_sse.cc") || ends_with(f, "_sse2.cc") continue;
            // named with their directory too: FFmpeg has both libavcodec/utils.c and libavutil/utils.c
            cc_out(*a, tprint("%/%_%.o", dir, path_filename(trim_right(path_strip_filename(f), "/")), path_filename(f)));
            array_add(*a, f);
            array_add(*list_jobs, a);
        }
        commands: String_Builder;
        for list_jobs { append(*commands, join(..it, " ")); append(*commands, "\n"); }
        all := builder_to_string(*commands);
        if !stale(stamp, path_strip_filename(list)) && same(stamp, all) continue;
        make_directory_if_it_does_not_exist(dir, recursive = true);
        for file_list(dir) file_delete(it);  // objects of files the list no longer names
        array_add(*jobs, ..list_jobs);
        array_add(*stamps, .{stamp, all});
    }
    if !run_parallel(jobs) return false;
    for stamps write_entire_file(it.path, it.commands);
    // The archive (and the .so) may hold another compiler's objects, from the last build of the other kind.
    shared_lib := !MAC_ARCH || HOST;
    want := ifx ANDROID then OBJ() else ifx HOST then "host" else ifx LINUX then "linux" else "cross_cc-v2";
    other := shared_lib && vendor_lib_target() != want;
    // vendor/<lib>/.shared names a shared library linked from that library's objects instead of the archive
    // (Linux only): FFmpeg's AAC decoder is LGPL, so the app opens libfc_aac.so with dlopen and a user can swap it.
    for dir: vendor_dirs() {
        name, shared := read_entire_file(tprint("%/.shared", dir), log_errors = false);
        if !shared || ANDROID continue; // @Incomplete: Android has no AAC library yet (TODO.md, Android step 10).
        so := tprint("build/%", trim(name));
        objs := vendor_outputs(tprint("%/", dir));
        m, _, ok := file_modtime_and_size(so);
        for objs if file_modtime_and_size(it) > m ok = false;
        if ok && !other continue;
        a: [..]string;
        if HOST array_add(*a, "cc", "-shared", "-s", "-Wl,--gc-sections", "-o", so);
        else array_add(*a, CROSS, "cc", "-target", GLIBC, "-shared", "-s", "-Wl,--gc-sections", "-o", so);
        array_add(*a, ..objs);
        array_add(*a, "-lm", "-lpthread");
        if run_command(..a).exit_code != 0 return false;
    }
    // One archive for the Jai side: every module's `#library,no_dll "../../build/fc_vendor"`.
    lib := VENDOR_LIB();
    m, _, ok := file_modtime_and_size(lib);
    need := !ok || other;
    objs := vendor_outputs();
    for objs { t := file_modtime_and_size(it); if t > m need = true; }
    if !need return true;
    file_delete(lib);
    // the object list goes in a response file: it is longer than a Windows command line
    rsp := tprint("%.rsp", lib);
    write_entire_file(rsp, join(..objs, "\n"));
    if ANDROID ok = run_command(join(NDK_BIN, "/llvm-ar", NDK_EXE,, temp), "rcs", lib, tprint("@%", rsp)).exit_code == 0;
    else if MSVC() ok = run_command(tprint("%\\lib.exe", MSVC_BIN), "/NOLOGO", tprint("/OUT:%", lib), tprint("@%", rsp)).exit_code == 0;
    else if HOST && !LINUX ok = run_command("libtool", "-static", "-no_warning_for_no_symbols", "-o", lib, "-filelist", rsp).exit_code == 0;
    else if HOST ok = run_command("ar", "rcs", lib, tprint("@%", rsp)).exit_code == 0;
    else ok = run_command(CROSS, "ar", "rcs", lib, tprint("@%", rsp)).exit_code == 0;
    return ok && (!shared_lib || set_vendor_lib_target(want));
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
