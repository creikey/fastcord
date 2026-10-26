package app

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "fc:gfx"
import "fc:locks"

// A frame that runs longer than this is reported as a hang: once per stuck frame, to stderr and to
// <data>/logs/hang-<unix time>.txt, with the frame phase, the lock the main thread is blocked on and
// its holder, and (on Windows) every thread's stack. The app keeps running so a debugger can attach.
HANG_SECONDS :: 5

Frame_Phase :: enum i32 {
	Idle,
	Poll,
	Media,
	UI,
	Render,
}

@(private = "file")
Watchdog :: struct {
	main_tid:    int,
	frame_start: i64, // time.now() in ns when the current frame began, 0 between frames.
	phase:       Frame_Phase,
	reported:    i64, // frame_start of the frame last reported.
}

@(private = "file")
wd: Watchdog

watchdog_start :: proc() {
	wd.main_tid = sync.current_thread_id()
	thread.create_and_start(watchdog_proc, self_cleanup = true)
}

watchdog_frame_begin :: proc() {
	sync.atomic_store(&wd.phase, Frame_Phase.Poll)
	sync.atomic_store(&wd.frame_start, time.to_unix_nanoseconds(time.now()))
}

watchdog_phase :: proc(p: Frame_Phase) {
	sync.atomic_store(&wd.phase, p)
}

watchdog_frame_end :: proc() {
	sync.atomic_store(&wd.frame_start, 0)
	sync.atomic_store(&wd.phase, Frame_Phase.Idle)
}

// gfx failures (draws with dead texture handles, failed texture creation or Present, atlas resets)
// go to <data>/logs/gfx.txt. The watchdog thread writes the file so the UI thread never waits on disk.
@(private = "file")
Gfx_Report :: struct {
	diag:        gfx.Diag,
	stats:       gfx.Frame_Stats,
	textures:    int,
	atlas_pages: int,
	frame:       u64,
	seq:         u64,
}

@(private = "file")
gfx_report_mu: locks.Mutex
@(private = "file")
gfx_report: Gfx_Report

// Main thread, after each rendered frame.
watchdog_gfx :: proc() {
	@(static) last: gfx.Diag
	d := gfx.diag()
	if d == last do return
	last = d
	r := Gfx_Report{diag = d, stats = gfx.stats(), textures = gfx.texture_count(), atlas_pages = gfx.text_stats().atlas_pages, frame = app.frame}
	locks.lock(&gfx_report_mu)
	r.seq = gfx_report.seq + 1
	gfx_report = r
	locks.unlock(&gfx_report_mu)
}

@(private = "file")
write_gfx_report :: proc() {
	@(static) written: u64
	@(static) written_at: time.Time
	locks.lock(&gfx_report_mu)
	r := gfx_report
	locks.unlock(&gfx_report_mu)
	// A failure that repeats every frame would otherwise add a line every second.
	if r.seq == written || time.since(written_at) < 5 * time.Second do return
	written = r.seq
	written_at = time.now()
	d := r.diag
	stamp, _ := time.time_to_rfc3339(written_at, include_nanos = false, allocator = context.temp_allocator)
	line := fmt.tprintfln(
		"%s frame %d: dead_tex_draws %d (last handle %d), tex_create_fails %d, present_fails %d, hresult 0x%08x, device_removed 0x%08x, atlas_resets %d; instances %d, draw_calls %d, textures %d, atlas_pages %d",
		stamp, r.frame, d.dead_tex_draws, d.last_dead_tex, d.tex_create_fails, d.present_fails, u32(d.last_hresult), u32(d.device_removed), d.atlas_resets,
		r.stats.instances, r.stats.draw_calls, r.textures, r.atlas_pages,
	)
	dir := app_data_dir("logs")
	os.make_directory_all(dir)
	f, err := os.open(fmt.tprintf("%s/gfx.txt", dir), {.Write, .Create, .Append})
	if err != nil do return
	os.write_string(f, line)
	os.close(f)
}

@(private = "file")
watchdog_proc :: proc() {
	for {
		time.sleep(time.Second)
		write_gfx_report()
		free_all(context.temp_allocator)
		start := sync.atomic_load(&wd.frame_start)
		if start == 0 || start == wd.reported do continue
		stuck := time.Duration(time.to_unix_nanoseconds(time.now()) - start)
		if stuck < HANG_SECONDS * time.Second do continue
		wd.reported = start
		report_hang(stuck)
		free_all(context.temp_allocator)
	}
}

@(private = "file")
report_hang :: proc(stuck: time.Duration) {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintfln(&b, "fastcord hang: frame running for %v, phase %v, main thread %d", stuck, sync.atomic_load(&wd.phase), wd.main_tid)
	if w := locks.waiting_on(wd.main_tid); w.waiting {
		fmt.sbprintfln(&b, "main thread is waiting for the lock taken at %v", w.wait_loc)
		if w.owner != 0 do fmt.sbprintfln(&b, "  held by thread %d since %v", w.owner, w.owner_loc)
		else do fmt.sbprintln(&b, "  which no thread holds: its state was corrupted (struct overwritten or copied while locked?)")
	}
	write_thread_stacks(&b, wd.main_tid)
	text := strings.to_string(b)
	fmt.eprint(text)
	dir := app_data_dir("logs")
	os.make_directory_all(dir)
	path := fmt.tprintf("%s/hang-%d.txt", dir, time.to_unix_seconds(time.now()))
	if os.write_entire_file(path, transmute([]byte)text) == nil do fmt.eprintln("hang report written to", path)
}
