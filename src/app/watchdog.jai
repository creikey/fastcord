// A frame that runs longer than this is reported as a hang: once per stuck frame, to stderr and to
// <data>/logs/hang-<unix time>.txt, with the frame phase, the lock the main thread is blocked on and
// its holder, and (on Windows) every thread's stack. The app keeps running so a debugger can attach.
HANG_SECONDS :: 5;

Frame_Phase :: enum s32 {
	Idle;
	Poll;
	Media;
	UI;
	Render;
}

watchdog_start :: () {
	wd.main_tid = locks.current_thread_id();
	#if OS != .WINDOWS main_thread = prof.current_thread();
	dc.spawn(cast(*void) null, watchdog_proc); // runs until the process exits
}

watchdog_frame_begin :: () {
	atomic_store(*wd.phase, Frame_Phase.Poll);
	atomic_store(*wd.frame_start, mono_ns());
}

watchdog_phase :: (p: Frame_Phase) {
	atomic_store(*wd.phase, p);
}

watchdog_frame_end :: () {
	atomic_store(*wd.frame_start, 0);
	atomic_store(*wd.phase, Frame_Phase.Idle);
}

// Main thread, after each rendered frame.
watchdog_gfx :: () {
	d := gfx.diag();
	if same_diag(d, last_diag) return;
	last_diag = d;
	r := Gfx_Report.{diag = d, stats = gfx.stats(), textures = gfx.texture_count(), atlas_pages = gfx.text_stats().atlas_pages, frame = app.frame};
	locks.lock(*gfx_report_mu);
	r.seq = gfx_report.seq + 1;
	gfx_report = r;
	locks.unlock(*gfx_report_mu);
}

// fastcord's log for bug reports: what goes through the logger (log_error and the like) also lands in
// <data>/logs/fastcord.log, which the watchdog thread appends each second; past LOG_MAX it is renamed
// fastcord.old.log and a new one starts. Log lines name errors and paths, never tokens, cookies or message
// text. main installs it as context.logger, so every thread started after it inherits it.
log_to_file :: (message: string, data: *void, info: Log_Info) {
	runtime_support_default_logger(message, data, info); // stderr, as before
	locks.guard(*lg.mu);
	lg.pending.allocator = context.default_allocator; // never a caller's pushed temp
	if builder_string_length(*lg.pending) + message.count > LOG_PENDING_MAX return; // a flood within one second
	t := to_calendar(current_time_consensus(), .UTC);
	print_to_builder(*lg.pending, "%-%-% %:%:%Z %\n", t.year, two(t.month_starting_at_0 + 1), two(t.day_of_month_starting_at_0 + 1), two(t.hour), two(t.minute), two(t.second), trim_right(message, "\n"));
}

LOG_MAX :: 1 << 20;
LOG_PENDING_MAX :: 64 * 1024;

// The watchdog thread each second, and fail before it exits: appends what was logged since the last second.
flush_log :: () {
	text: string;
	{
		locks.guard(*lg.mu);
		if builder_string_length(*lg.pending) == 0 return;
		text = builder_to_string(*lg.pending,, context.default_allocator);
	}
	defer free(text);
	dir := app_data_dir("logs");
	make_directory_if_it_does_not_exist(dir, recursive = true);
	path := tprint("%/fastcord.log", dir);
	f, ok := file_open(path, for_writing = true, keep_existing_content = true, log_errors = false);
	if !ok return;
	size := file_length(f);
	if size + text.count > LOG_MAX {
		file_close(*f);
		old := tprint("%/fastcord.old.log", dir);
		file_delete(old);
		file_move(path, old);
		f, ok = file_open(path, for_writing = true, log_errors = false);
		if !ok return;
		size = 0;
	}
	file_set_position(f, size);
	file_write(*f, text);
	file_close(*f);
}

#scope_file

lg: struct {
	mu: locks.Mutex;
	pending: String_Builder; // heap
};

two :: (x: s64) -> string { return tprint("%", formatInt(x, minimum_digits = 2)); }

wd: struct {
	main_tid: int;
	frame_start: s64; // monotonic ns when the current frame began, 0 between frames.
	phase: Frame_Phase;
	reported: s64; // frame_start of the frame last reported.
};

mono_ns :: () -> s64 { return to_nanoseconds(current_time_monotonic()); }

// gfx failures (draws with dead texture handles, failed texture creation or Present, atlas resets)
// go to <data>/logs/gfx.txt. The watchdog thread writes the file so the UI thread never waits on disk.
Gfx_Report :: struct {
	diag: gfx.Diag;
	stats: gfx.Frame_Stats;
	textures: int;
	atlas_pages: int;
	frame: u64;
	seq: u64;
}

gfx_report_mu: locks.Mutex;
gfx_report: Gfx_Report;
last_diag: gfx.Diag; // main thread
written: u64; // watchdog thread: seq of the report last written, and when (monotonic ns)
written_at: s64;

same_diag :: (a: gfx.Diag, b: gfx.Diag) -> bool {
	return a.dead_tex_draws == b.dead_tex_draws && a.last_dead_tex == b.last_dead_tex && a.tex_create_fails == b.tex_create_fails && a.present_fails == b.present_fails && a.last_hresult == b.last_hresult && a.device_removed == b.device_removed && a.atlas_resets == b.atlas_resets;
}

write_gfx_report :: () {
	locks.lock(*gfx_report_mu);
	r := gfx_report;
	locks.unlock(*gfx_report_mu);
	// A failure that repeats every frame would otherwise add a line every second.
	now := mono_ns();
	if r.seq == written || (written_at != 0 && now - written_at < 5_000_000_000) return;
	written, written_at = r.seq, now;
	d := r.diag;
	t := to_calendar(current_time_consensus(), .UTC);
	two :: (x: s64) -> string { return tprint("%", formatInt(x, minimum_digits = 2)); }
	stamp := tprint("%-%-%T%:%:%Z", t.year, two(t.month_starting_at_0 + 1), two(t.day_of_month_starting_at_0 + 1), two(t.hour), two(t.minute), two(t.second));
	hex8 :: (x: s32) -> string { return tprint("%", formatInt(cast,no_check(u32) x, base = 16, minimum_digits = 8)); }
	line := tprint("% frame %: dead_tex_draws % (last handle %), tex_create_fails %, present_fails %, hresult 0x%, device_removed 0x%, atlas_resets %; instances %, draw_calls %, textures %, atlas_pages %\n",
		stamp, r.frame, d.dead_tex_draws, d.last_dead_tex, d.tex_create_fails, d.present_fails, hex8(d.last_hresult), hex8(d.device_removed), d.atlas_resets,
		r.stats.instances, r.stats.draw_calls, r.textures, r.atlas_pages);
	dir := app_data_dir("logs");
	make_directory_if_it_does_not_exist(dir, recursive = true);
	f, ok := file_open(tprint("%/gfx.txt", dir), for_writing = true, keep_existing_content = true, log_errors = false);
	if !ok return;
	file_set_position(f, file_length(f));
	file_write(*f, line);
	file_close(*f);
}

watchdog_proc :: (_: *void) {
	while true {
		sleep_milliseconds(1000);
		flush_log();
		write_gfx_report();
		reset_temporary_storage();
		start := atomic_load(*wd.frame_start);
		if start == 0 || start == wd.reported continue;
		stuck_ns := mono_ns() - start;
		if stuck_ns < HANG_SECONDS * 1_000_000_000 continue;
		wd.reported = start;
		report_hang(stuck_ns);
		reset_temporary_storage();
	}
}

report_hang :: (stuck_ns: s64) {
	b: String_Builder;
	b.allocator = temp;
	print_to_builder(*b, "fastcord hang: frame running for %s, phase %, main thread %\n", formatFloat(cast(float64) stuck_ns / 1_000_000_000, trailing_width = 3, zero_removal = .NO), atomic_load(*wd.phase), wd.main_tid);
	w := locks.waiting_on(wd.main_tid);
	if w.waiting {
		print_to_builder(*b, "main thread is waiting for the lock taken at %\n", loc(w.wait_loc));
		if w.owner != 0 print_to_builder(*b, "  held by thread % since %\n", w.owner, loc(w.owner_loc));
		else append(*b, "  which no thread holds: its state was corrupted (struct overwritten or copied while locked?)\n");
	}
	write_thread_stacks(*b, wd.main_tid);
	text := builder_to_string(*b,, temp);
	print("%", text, to_standard_error = true);
	dir := app_data_dir("logs");
	make_directory_if_it_does_not_exist(dir, recursive = true);
	path := tprint("%/hang-%.txt", dir, to_seconds(current_time_consensus() - dc.UNIX_EPOCH));
	if write_entire_file(path, text) log_error("hang report written to %", path);
}

loc :: (l: Source_Code_Location) -> string { return tprint("%(%:%)", l.fully_pathed_filename, l.line_number, l.character_number); }
