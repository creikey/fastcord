libc :: #system_library "libc";
pid_t :: s32;
timeval :: struct { tv_sec: s64; tv_usec: s32; }
rusage :: struct { ru_utime: timeval; ru_stime: timeval; rest: [14]s64; }
Rusage_Who :: enum s32 { SELF :: 0; CHILDREN :: -1; }
Result :: enum s32 { OK :: 0; FAIL :: -1; }
getrusage :: (who: Rusage_Who, r: *rusage) -> Result #foreign libc;
