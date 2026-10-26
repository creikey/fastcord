#+build darwin
package discord

import "core:sys/darwin"
import "core:sys/posix"
import "core:time"

@(private)
Mach_Task_Basic_Info :: struct {
	virtual_size:      u64,
	resident_size:     u64,
	resident_size_max: u64,
	user_time:         [2]i32,
	system_time:       [2]i32,
	policy:            i32,
	suspend_count:     i32,
}

MACH_TASK_BASIC_INFO :: 20

@(private)
_process_resident_bytes :: proc() -> (i64, bool) {
	info: Mach_Task_Basic_Info
	count := u32(size_of(Mach_Task_Basic_Info) / 4)
	kr := darwin.task_info(darwin.mach_task_self(), MACH_TASK_BASIC_INFO, darwin.task_info_t(rawptr(&info)), &count)
	if kr != .Success do return 0, false
	return i64(info.resident_size), true
}

@(private)
_process_cpu_time :: proc() -> (time.Duration, bool) {
	ru: posix.rusage
	if posix.getrusage(.SELF, &ru) != .OK do return 0, false
	us := i64(ru.ru_utime.tv_sec) * 1_000_000 + i64(ru.ru_utime.tv_usec) + i64(ru.ru_stime.tv_sec) * 1_000_000 + i64(ru.ru_stime.tv_usec)
	return time.Duration(us) * time.Microsecond, true
}
