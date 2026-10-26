package prof

import "core:strings"
import "core:testing"
import "core:time"

@(test)
test_zones :: proc(t: ^testing.T) {
	z: Zones
	defer zones_destroy(&z)
	{
		zone("outside") // not recorded: zones_begin not called yet
	}
	zones_begin(&z, trace = true)
	for _ in 0 ..< 3 {
		zone("outer")
		{
			zone("inner")
			time.sleep(time.Millisecond)
		}
	}
	zones_end()
	{
		zone("after")
	}
	testing.expect_value(t, len(z.stats), 2)
	inner := zone_stat(&z, "inner")
	outer := zone_stat(&z, "outer")
	testing.expect_value(t, inner.calls, 3)
	testing.expect_value(t, outer.calls, 3)
	testing.expect(t, inner.ns >= 3 * i64(time.Millisecond), "inner zone too short")
	testing.expect(t, outer.ns >= inner.ns, "outer must include inner")
	testing.expect_value(t, len(z.events), 6)
	testing.expect(t, strings.contains(zones_report(&z), "inner"))
}

@(private = "file")
spin :: #force_no_inline proc(x: ^u64) {
	for _ in 0 ..< 1000 do x^ = x^ * 6364136223846793005 + 1442695040888963407
}

@(private = "file")
busy_work :: #force_no_inline proc(d: time.Duration) -> u64 {
	x: u64 = 1
	start := time.tick_now()
	for time.tick_since(start) < d do spin(&x)
	return x
}

@(test)
test_sampler_finds_hot_procedure :: proc(t: ^testing.T) {
	s: Sampler
	defer sampler_destroy(&s)
	gate: i32 = 1
	testing.expect(t, sampler_start(&s, current_thread(), 1000, &gate))
	busy_work(300 * time.Millisecond)
	gate = 0
	time.sleep(50 * time.Millisecond)
	sampler_stop(&s)
	testing.expectf(t, s.samples >= 20, "only %d samples (%d failed)", s.samples, s.failed)
	testing.expect(t, s.skipped > 0, "the closed gate should skip samples")

	syms := resolve_symbols(&s, context.temp_allocator)
	Ctx :: struct {
		syms: ^map[u64]Symbol,
		hits: int,
	}
	c := Ctx{syms = &syms}
	each_sample(&s, proc(frames: []u64, user: rawptr) -> bool {
		c := (^Ctx)(user)
		for a in frames {
			if strings.contains(c.syms[a].procedure, "busy_work") {
				c.hits += 1
				break
			}
		}
		return true
	}, &c)
	testing.expectf(t, c.hits * 2 >= s.samples, "busy_work on %d of %d stacks", c.hits, s.samples)
	report := sampler_report(&s, 10)
	testing.expect(t, strings.contains(report, "spin"), report)
}
