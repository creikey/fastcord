libc :: #system_library "libc";
task_info_t :: *s32;
Kern_Return :: enum s32 { Success :: 0; }
PIDPATHINFO_MAXSIZE :: 4096;
mach_task_self_: u32 #elsewhere libc;
mach_task_self :: () -> u32 { return mach_task_self_; }
task_info :: (task: u32, flavor: s32, info: task_info_t, count: *u32) -> Kern_Return #foreign libc;
proc_listallpids :: (buf: *s32, size: s32) -> s32 #foreign libc;
proc_pidpath :: (pid: s32, buf: *u8, size: u32) -> s32 #foreign libc;
