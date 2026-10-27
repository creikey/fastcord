// jai build.jai - [app|dev|debug|parity|run <file.jai>|tool <name>|c]
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
    if target == "c" return;

    w := compiler_create_workspace(target);
    o := get_build_options(w);
    import_path: [..]string;
    array_add(*import_path, "jai");
    array_add(*import_path, ..o.import_path);
    o.import_path = import_path;
    o.use_custom_link_command = true;
    o.text_output_flags = 0;
    file := "jai/app/main.jai";
    if target == {
        case "app";   o.output_executable_name = "fastcord"; set_optimization(*o, .VERY_OPTIMIZED);
        case "dev";   o.output_executable_name = "fastcord-dev"; set_optimization(*o, .OPTIMIZED);
        case "debug"; o.output_executable_name = "fastcord-debug"; set_optimization(*o, .DEBUG);
        case "tool";  o.output_executable_name = args[1]; file = tprint("jai/tool_%/main.jai", args[1]);
        case "parity"; o.output_executable_name = "parity"; file = "jai/discord_parity/module.jai";
        case "run";  file = args[1]; o.output_executable_name = path_strip_extension(path_filename(file));
        case; log_error("usage: jai build.jai - [app|dev|debug|parity|run <file.jai>|tool <name>|c]"); return;
    }
    o.output_path = "build";
    o.dead_code_elimination = .NONE; // type-check every procedure, not only the ones called
    o.cast_bounds_check = .OFF;      // integer casts truncate, as the code base (written for Odin) expects
    set_build_options(o, w);
    compiler_begin_intercept(w);
    add_build_file(file, w);
    ok := true;
    while true {
        m := compiler_wait_for_message();
        if m.kind == .ERROR ok = false;
        if m.kind == .COMPLETE break;
        if m.kind == .PHASE {
            p := cast(*Message_Phase) m;
            if p.phase == .READY_FOR_CUSTOM_LINK_COMMAND {
                if !link(p, tprint("build/%", o.output_executable_name)) ok = false;
                compiler_custom_link_command_is_complete(w);
            }
        }
    }
    compiler_end_intercept(w);
    if !ok compiler_set_workspace_status(.FAILED);
}

MAC_FLAGS :: string.["-arch", "arm64", "-mmacosx-version-min=13.0"];

link :: (p: *Message_Phase, exe: string) -> bool {
    a: [..]string;
    array_add(*a, "clang", "-o", exe);
    #if OS == .MACOS array_add(*a, ..MAC_FLAGS);
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
        #if OS == .MACOS array_add(*a, ..MAC_FLAGS);
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
            #if OS == .MACOS array_add(*a, ..MAC_FLAGS);
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
