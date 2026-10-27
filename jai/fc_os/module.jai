// Files, environment and processes. An Error is null on success.
#import "Basic";
Basic :: #import "Basic";
#import "fc";
F :: #import "File";
FU :: #import "File_Utilities";
P :: #import "Process";
S :: #import "String";
Sys :: #import "System";

Error_Info :: struct { msg: string; }
Error :: *Error_Info;
GENERAL :: Error_Info.{"os error"};
NOT_EXIST :: Error_Info.{"not found"};
fail :: () -> Error { return *GENERAL; }

File :: struct { f: F.File; dir: string; }
File_Flag_Set :: enum_flags u8 { Read; Write; Create; Append; Trunc; }
File_Flags :: File_Flag_Set;
Permissions_Default_File :: 420;
File_Info :: struct { fullpath: string; name: string; size: s64; is_dir: bool; }

exit :: (code: int) { Basic.exit(cast(s32) code); }

read_entire_file :: (path: string, allocator := context.allocator) -> []u8, Error {
    push_allocator(allocator);
    s, ok := F.read_entire_file(path, log_errors = false);
    if !ok return .[], *NOT_EXIST;
    return to_bytes(s), null;
}
write_entire_file :: (path: string, data: []u8) -> Error { return ifx F.write_entire_file(path, data.data, data.count) then null else fail(); }
write_entire_file :: (path: string, data: string) -> Error { return ifx F.write_entire_file(path, data) then null else fail(); }

open :: (path: string, flags := File_Flag_Set.Read, perm := 0) -> *File, Error {
    f := New(File);
    ok: bool;
    if flags & .Write {
        f.f, ok = F.file_open(path, for_writing = true, keep_existing_content = !(flags & .Trunc) && (flags & .Append) != 0, log_errors = false);
        if ok && (flags & .Append) F.file_set_position(f.f, F.file_length(f.f));
    } else {
        if FU.is_directory(path) { f.dir = copy_string(path); return f, null; }
        f.f, ok = F.file_open(path, log_errors = false);
        if !ok && FU.file_exists(path) { f.dir = copy_string(path); ok = true; }
    }
    if !ok { free(f); return null, *NOT_EXIST; }
    return f, null;
}
create :: (path: string) -> *File, Error { f, e := open(path, .Write | .Create | .Trunc); return f, e; }
close :: (f: *File) -> Error { if f { if !f.dir F.file_close(*f.f); free(f); } return null; }
write_string :: (f: *File, s: string) -> int, Error {
    if f == stdout { print("%", s); return s.count, null; }
    return ifx F.file_write(*f.f, s) then s.count else 0, null;
}
write :: (f: *File, b: []u8) -> int, Error { n, e := write_string(f, as_string(b)); return n, e; }
read :: (f: *File, buf: []u8) -> int, Error {
    ok, n := F.file_read(f.f, buf.data, buf.count);
    if !ok return 0, fail();
    return n, null;
}
read_at :: (f: *File, buf: []u8, offset: s64) -> int, Error {
    F.file_set_position(f.f, offset);
    n, e := read(f, buf);
    return n, e;
}
file_size :: (f: *File) -> s64, Error { n, ok := F.file_length(f.f); return n, ifx ok then null else fail(); }
stat :: (path: string, allocator := context.allocator) -> File_Info, Error {
    _, size, ok := FU.file_modtime_and_size(path);
    if !ok return .{}, *NOT_EXIST;
    return .{fullpath = path, name = S.path_filename(path), size = size}, null;
}
exists :: (path: string) -> bool { return FU.file_exists(path); }
remove_ :: (path: string) -> Error { return ifx F.file_delete(path) then null else fail(); }
rename :: (a: string, b: string) -> Error { return ifx F.file_move(a, b) then null else fail(); }
make_directory :: (path: string, perm := 493) -> Error { return ifx F.make_directory_if_it_does_not_exist(path) then null else fail(); }
make_directory_all :: (path: string, perm := 493) -> Error { return ifx F.make_directory_if_it_does_not_exist(path, recursive = true) then null else fail(); }

// open(dir) + read_dir(fd, -1): list a directory's entries.
read_dir :: (f: *File, n: int, allocator := context.allocator) -> []File_Info, Error {
    out: [..]File_Info;
    out.allocator = allocator;
    FU.visit_files(f.dir, false, *out, (info: *FU.File_Visit_Info, out: *[..]File_Info) {
        array_add(out, .{fullpath = copy_string(info.full_name), name = copy_string(info.short_name), is_dir = info.is_directory});
    }, visit_directories = true);
    return out, null;
}

get_env :: (name: string, allocator := context.allocator) -> string {
    v, ok := get_environment_variable(name);
    if !ok return "";
    push_allocator(allocator);
    return copy_string(v);
}
#if OS != .WINDOWS {
    libc :: #system_library "libc";
    getenv :: (name: *u8) -> *u8 #foreign libc;
    getpid :: () -> s32 #foreign libc;
    get_environment_variable :: (name: string) -> string, bool {
        p := getenv(temp_c_string(name));
        if !p return "", false;
        return to_string(p), true;
    }
}
environ :: (allocator := context.allocator) -> []string, Error {
    out: [..]string;
    out.allocator = allocator;
    #if OS == .MACOS {
        _NSGetEnviron :: () -> ***u8 #foreign libc;
        e := _NSGetEnviron().*;
        while e && e.* { array_add(*out, to_string(e.*)); e += 1; }
    }
    return out, null;
}

stdout_file: File;
stdout := *stdout_file;
get_processor_core_count :: () -> int { return Sys.get_number_of_processors(); }
get_pid :: () -> int { #if OS == .WINDOWS return 0; else return getpid(); }

Process_Desc :: struct { command: []string; env: []string; stdout: *File; stderr: *File; working_dir: string; }
Process_State :: struct { exit_code: int; success: bool; exited: bool; }
Process :: struct { p: P.Process; }
process_exec :: (desc: Process_Desc, allocator := context.allocator) -> Process_State, []u8, []u8, Error {
    r, out, err := P.run_command(..desc.command, working_directory = desc.working_dir, capture_and_return_output = true);
    st := Process_State.{exit_code = r.exit_code, success = r.exit_code == 0, exited = true};
    push_allocator(allocator);
    return st, to_bytes(copy_string(out)), to_bytes(copy_string(err)), ifx r.type == .FAILED_TO_LAUNCH then fail() else null;
}
process_start :: (desc: Process_Desc) -> Process, Error {
    p: Process;
    if !P.create_process(*p.p, ..desc.command, working_directory = desc.working_dir) return p, fail();
    return p, null;
}
process_kill :: (p: Process) -> Error { pp := p; P.kill_process(*pp.p); return null; }
process_wait :: (p: Process) -> Process_State, Error {
    pp := p;
    _, r := P.get_process_result(*pp.p);
    return .{exit_code = r.exit_code, success = r.exit_code == 0, exited = true}, null;
}
