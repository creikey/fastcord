// Real process metrics for telemetry (the official client reports its own
// processes via discord_utils / processUtils; we report ours):
//   client_performance_memory   ceil(sum of process memory bytes / 1024)  (KB)
//   client_performance_cpu      % of one core used since the previous sample (rounded)
//   cpu_core_count              logical cores
//   uptime_process_renderer     whole seconds since this process started

record_process_start :: () { process_start = current_time_monotonic(); }

process_uptime_seconds :: () -> s64 { return to_milliseconds(current_time_monotonic() - process_start) / 1000; }

process_memory_kb :: () -> s64, bool {
	b, ok := process_resident_bytes();
	if !ok return 0, false;
	return (b + 1023) / 1024, true;
}

// process_cpu_percent: like Electron's getCPUUsage().percentCPUUsage (one core = 100).
process_cpu_percent :: () -> float64, bool {
	cpu_ns, ok := process_cpu_ns();
	if !ok return 0, false;
	using cpu_sampler;
	locks.lock(*mu);
	defer locks.unlock(*mu);
	now := current_time_monotonic();
	if !have {
		last_cpu_ns, last, have = cpu_ns, now, true;
		return 0, true;
	}
	wall_ns := to_nanoseconds(now - last);
	used_ns := cpu_ns - last_cpu_ns;
	last_cpu_ns, last = cpu_ns, now;
	if wall_ns <= 0 return 0, true;
	return cast(float64) used_ns / cast(float64) wall_ns * 100, true;
}

#scope_file

process_start: Apollo_Time;

cpu_sampler: struct {
	mu: locks.Mutex;
	last_cpu_ns: s64;
	last: Apollo_Time;
	have: bool;
};
