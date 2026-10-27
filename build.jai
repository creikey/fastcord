// jai build.jai - [app|dev|debug|parity|test [names]|run <file.jai>|tool <name>|release <vX.Y.Z> [publish]|c]
// Compiles the vendored C libraries (each vendor/<lib>/fc_<lib>.c, or the files listed in fc_<lib>.sources)
// into build/, then the Jai program, then links everything with the system clang.
#import "Basic";
#import "Compiler";
#import "Process";
#import "File";
#import "File_Utilities";
#import "String";
#import "Thread";

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
        case "parity"; ok = compile("parity", file = "jai/discord_parity/module.jai");
        case "run";    ok = compile(path_strip_extension(path_filename(args[1])), file = args[1]);
        case "test";
            // the offline traffic-parity tests; extra arguments pick tests by name
            ok = compile("test-discord-jai", file = "jai/tests/discord.jai", optimization = .OPTIMIZED);
            if ok {
                a: [..]string;
                array_add(*a, "build/test-discord-jai");
                for 1..args.count-1 array_add(*a, args[it]);
                ok = run_command(..a).exit_code == 0;
            }
        case "release"; ok = release(args);
        case; log_error("usage: jai build.jai - [app|dev|debug|parity|test [names]|run <file.jai>|tool <name>|release <vX.Y.Z> [publish]|c]"); return;
    }
    if !ok compiler_set_workspace_status(.FAILED);
}

// compile builds one program into build/<name>: the root is a file or a build string.
compile :: (name: string, source := "", optimization := Optimization_Type.DEBUG, file := "", cpu := CPU) -> bool {
    w := compiler_create_workspace(name);
    o := get_build_options(w);
    import_path: [..]string;
    array_add(*import_path, "jai");
    for o.import_path array_add(*import_path, it);
    o.import_path = import_path;
    o.use_custom_link_command = true;
    o.text_output_flags = 0;
    o.output_executable_name = name;
    o.output_path = "build";
    o.cpu_target = cpu;
    o.dead_code_elimination = .NONE; // type-check every procedure, not only the ones called
    o.cast_bounds_check = .OFF;      // integer casts truncate, as the wire encoders expect
    set_optimization(*o, optimization);
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
    if !compile("fastcord-x86_64", root, .VERY_OPTIMIZED, cpu = .X64) return false;
    app := "build/pkg/Fastcord.app";
    run_command("rm", "-rf", "build/pkg", "dist");
    make_directory_if_it_does_not_exist(tprint("%/Contents/MacOS", app), recursive = true);
    make_directory_if_it_does_not_exist(tprint("%/Contents/Resources", app), recursive = true);
    make_directory_if_it_does_not_exist("dist");
    plain := slice(version, 1, version.count - 1);
    plist := tprint(INFO_PLIST, plain, plain);
    ok := run_command("lipo", "-create", "build/fastcord-arm64", "build/fastcord-x86_64", "-output", tprint("%/Contents/MacOS/Fastcord", app)).exit_code == 0
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
