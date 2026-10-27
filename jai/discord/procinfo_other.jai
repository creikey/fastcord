#scope_module

_process_resident_bytes :: () -> s64, bool {return 0, false;}

_process_cpu_time :: () -> time.Duration, bool {return 0, false;}
#scope_export

process_exe_paths :: (allocator := context.allocator) -> []string {return .{};}

