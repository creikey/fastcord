package discord

import "core:sync"
import "core:time"

// Real process metrics for telemetry (the official client reports its own
// processes via discord_utils / processUtils; we report ours):
//   client_performance_memory   ceil(sum of process memory bytes / 1024)  (KB)
//   client_performance_cpu      % of one core used since the previous sample (rounded)
//   cpu_core_count              logical cores
//   uptime_process_renderer     whole seconds since this process started

@(private)
process_start_tick: time.Tick

@(init, private)
record_process_start :: proc "contextless" () {
	process_start_tick = time.tick_now()
}

process_uptime_seconds :: proc() -> i64 {
	return i64(time.duration_seconds(time.tick_since(process_start_tick)))
}

process_memory_kb :: proc() -> (kb: i64, ok: bool) {
	b, bok := _process_resident_bytes()
	if !bok do return 0, false
	return (b + 1023) / 1024, true
}

@(private)
Cpu_Sampler :: struct {
	mu:       sync.Mutex,
	last_cpu: time.Duration,
	last:     time.Tick,
	have:     bool,
}

@(private)
cpu_sampler: Cpu_Sampler

// process_cpu_percent: like Electron's getCPUUsage().percentCPUUsage (one core = 100).
process_cpu_percent :: proc() -> (pct: int, ok: bool) {
	cpu, cok := _process_cpu_time()
	if !cok do return 0, false
	sync.mutex_lock(&cpu_sampler.mu)
	defer sync.mutex_unlock(&cpu_sampler.mu)
	now := time.tick_now()
	if !cpu_sampler.have {
		cpu_sampler = {last_cpu = cpu, last = now, have = true}
		return 0, true
	}
	wall := time.tick_diff(cpu_sampler.last, now)
	used := cpu - cpu_sampler.last_cpu
	cpu_sampler.last_cpu = cpu
	cpu_sampler.last = now
	if wall <= 0 do return 0, true
	return int(f64(used) / f64(wall) * 100 + 0.5), true
}
