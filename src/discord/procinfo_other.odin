#+build !darwin
#+build !windows
package discord

import "core:time"

@(private)
_process_resident_bytes :: proc() -> (i64, bool) {return 0, false}

@(private)
_process_cpu_time :: proc() -> (time.Duration, bool) {return 0, false}

process_exe_paths :: proc(allocator := context.allocator) -> []string {return nil}
