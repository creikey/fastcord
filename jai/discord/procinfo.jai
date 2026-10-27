#scope_module

// Real process metrics for telemetry (the official client reports its own
// processes via discord_utils / processUtils; we report ours):
//   client_performance_memory   ceil(sum of process memory bytes / 1024)  (KB)
//   client_performance_cpu      % of one core used since the previous sample (rounded)
//   cpu_core_count              logical cores
//   uptime_process_renderer     whole seconds since this process started

// Real process metrics for telemetry (the official client reports its own
// processes via discord_utils / processUtils; we report ours):
//   client_performance_memory   ceil(sum of process memory bytes / 1024)  (KB)
//   client_performance_cpu      % of one core used since the previous sample (rounded)
//   cpu_core_count              logical cores
//   uptime_process_renderer     whole seconds since this process started

process_start_tick: time.Tick;
#scope_export

record_process_start :: () #no_context {
	process_start_tick = time.tick_now();
}

process_uptime_seconds :: () -> s64 {
	return cast(s64)(time.duration_seconds(time.tick_since(process_start_tick)));
}

process_memory_kb :: () -> s64, bool {
	kb: s64;
	ok: bool;
	b, bok := _process_resident_bytes();
	if !bok { return 0, false; }
	return (b + 1023) / 1024, true;
}
#scope_module

Cpu_Sampler :: struct {
	mu: locks.Mutex;
	last_cpu: time.Duration;
	last: time.Tick;
	have: bool;
}

cpu_sampler: Cpu_Sampler;
#scope_export

// process_cpu_percent: like Electron's getCPUUsage().percentCPUUsage (one core = 100).
process_cpu_percent :: () -> float64, bool {
	pct: float64;
	ok: bool;
	cpu, cok := _process_cpu_time();
	if !cok { return 0, false; }
	locks.lock(*cpu_sampler.mu);
	defer locks.unlock(*cpu_sampler.mu);
	now := time.tick_now();
	if !cpu_sampler.have {
		cpu_sampler.last_cpu = cpu;
		cpu_sampler.last = now;
		cpu_sampler.have = true;
		return 0, true;
	}
	wall := time.tick_diff(cpu_sampler.last, now);
	used := cpu - cpu_sampler.last_cpu;
	cpu_sampler.last_cpu = cpu;
	cpu_sampler.last = now;
	if wall <= 0 { return 0, true; }
	return cast(float64)(used) / cast(float64)(wall) * 100, true;
}

