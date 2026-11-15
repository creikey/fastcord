// Call transcription (fastcord-only; TRANSCRIPTION.md). Every speaker's audio is turned into text on this
// machine by src/stt: nothing about the call leaves it. Lines show live in a pane beside the call and are
// appended to one markdown file per call in <data>/transcripts. Off by default. Unless Transcribe Everyone
// is on, only people whose voice gateway flags allow voice recording (Discord's "Allow my voice to be
// recorded in Clips") are transcribed; the others show once as not transcribed. The model is downloaded on
// first use from its pinned URL and checked against its pinned sha256.

STT_MODELS :: stt.Model.[
	.{id = "base-en", name = "Fast (English, 60 MB)", file = "ggml-base.en-q5_1.bin",
		url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en-q5_1.bin",
		sha256 = "4baf70dd0d7c4247ba2b81fafd9c01005ac77c2f9ef064e00dcf195d0e2fdd2f", size = 59721011, kind = .Whisper, english_only = true},
	.{id = "parakeet-v3", name = "Accurate (25 European languages, 669 MB)", file = "ggml-parakeet-tdt-0.6b-v3-q8_0.bin",
		url = "https://huggingface.co/ggml-org/parakeet-GGUF/resolve/main/ggml-parakeet-tdt-0.6b-v3-q8_0.bin",
		sha256 = "4d64e9e96c2792186d072fde0034df0ad670cf680a2f53069052ead827fd600e", size = 668757119, kind = .Parakeet},
];
STT_DEFAULT_MODEL :: "base-en";

Transcribe :: struct {
	on: bool;          // persisted: Transcribe Calls
	everyone: bool;    // persisted: also people whose voice recording is off
	model: string;     // persisted: STT_MODELS id (heap)
	pane_open := true; // the call's transcript pane
	// the chosen model's file: unknown until checked off the UI thread
	checked_id: string; // heap: the model the check below is for
	check: *Model_Check;
	present: bool;
	// a download of checked_id
	dl: *dc.Media_Progress;
	dl_id: string; // heap
	dl_failed: bool;
	verify: *Model_Check; // the downloaded file's sha256, then its rename into place
	// this call
	active: bool;
	channel: dc.Snowflake;
	path: string; // heap: the call's transcript file, when there's no vault
	lines: [..]Transcript_Line;
	// Once a vault exists in fastcord.db, calls are sealed into it instead of written to files (src/vault).
	vault_has: *vault.Has; // The startup question, until answered.
	vault_known, vault_found: bool;
	call: *vault.Call;     // This call's, until its last write is done.
	writes: [..]*vault.Write;
}

Transcript_Line :: struct {
	who: string;    // heap
	at_ms: s64;
	text: string;   // heap; "" for a note
	note: string;   // heap: not transcribed, or audio skipped
}

Model_Check :: struct { path, part, sha256: string; size: s64; done, ok: bool; }

transcript: Transcribe;

transcribe_restore :: (p: *Persisted_Voice) {
	transcript.on, transcript.everyone = p.transcribe, p.transcribe_everyone;
	free(transcript.model);
	transcript.model = copy_string(ifx stt_model_find(p.transcribe_model) then p.transcribe_model else STT_DEFAULT_MODEL);
}

transcribe_snapshot :: (p: *Persisted_Voice) {
	p.transcribe, p.transcribe_everyone, p.transcribe_model = transcript.on, transcript.everyone, transcript.model;
}

stt_model_find :: (id: string) -> *stt.Model {
	for * STT_MODELS if it.id == id return it;
	return null;
}

stt_model :: () -> *stt.Model {
	m := stt_model_find(transcript.model);
	return ifx m then m else *STT_MODELS[0];
}

stt_model_path :: (m: *stt.Model) -> string { return tprint("%/%", app_data_dir("models"), m.file); }

// The voice connection's listen hook: on the voice thread, under its lock.
transcribe_listen :: (data: *void, user_id: u64, pcm: []float32, channels: int, recordable: bool) {
	stt.feed(user_id, pcm, channels, recordable);
}

// transcribe_frame: starts and stops transcribing with the call, takes finished lines (UI thread).
transcribe_frame :: () {
	m := stt_model();
	if transcript.checked_id != m.id && !transcript.check {
		free(transcript.checked_id);
		transcript.checked_id = copy_string(m.id);
		transcript.present = false;
		transcript.check = model_check_start(stt_model_path(m), "", m.size, "");
	}
	if transcript.check && atomic_load(*transcript.check.done) {
		if transcript.checked_id == m.id transcript.present = transcript.check.ok;
		model_check_free(transcript.check);
		transcript.check = null;
	}
	if transcript.verify && atomic_load(*transcript.verify.done) {
		ok := transcript.verify.ok;
		if !ok transcript.dl_failed = true;
		if ok && transcript.checked_id == transcript.dl_id transcript.present = true;
		model_check_free(transcript.verify);
		transcript.verify = null;
		free(transcript.dl_id);
		transcript.dl_id = "";
	}
	if transcript.dl || transcript.verify || transcript.check request_wake(platform.time_now() + 0.25);
	if transcript.on && !transcript.vault_known && !transcript.vault_has && e2e_db {
		transcript.vault_has = vault.has();
		e2e.submit(e2e_db, transcript.vault_has);
	}
	if transcript.vault_has && e2e.is_done(transcript.vault_has) {
		transcript.vault_found = transcript.vault_has.found && !transcript.vault_has.failed;
		transcript.vault_known = true;
		free(transcript.vault_has);
		transcript.vault_has = null;
	}
	for transcript.writes if e2e.is_done(it) {
		// Jobs run in order, so a call's last write is done only after all its others.
		if it.end_ms {
			if it.call.failed log_error("transcribe: a call's transcript couldn't be saved in full: %", ifx it.failed then e2e_db.error else "the database refused a write");
			vault.call_free(it.call);
		}
		vault.free_write(it);
		remove it;
	}

	want := transcript.on && transcript.present && transcript.vault_known && stt.supported() && app.voice_channel != 0 && !voice_headless_quiet();
	if want && (!transcript.active || transcript.channel != app.voice_channel) transcript_begin(m);
	else if !want && transcript.active transcript_end();

	got: [..]stt.Line;
	got.allocator = temp;
	stt.take(*got);
	if !got.count return;
	b: String_Builder;
	b.allocator = temp;
	sealed: [..]vault.Line;
	sealed.allocator = temp;
	s := call_store();
	ch := dc.channel_get(s, transcript.channel);
	gid := ifx ch then ch.guild_id else 0;
	for got {
		l := array_add(*transcript.lines);
		l.at_ms = it.start_ms;
		if it.dropped_ms {
			l.who = copy_string("");
			l.note = sprint(L("% s of speech not transcribed: this computer fell behind."), (it.dropped_ms + 999) / 1000);
		} else {
			l.who = copy_string(dc.user_name(s, cast(dc.Snowflake) it.user_id, gid, L("unknown")));
			if it.not_recordable l.note = copy_string(L("Not transcribed: their voice recording is off."));
			else l.text = it.text;
		}
		if transcript.call {
			kind := ifx it.dropped_ms then vault.Line_Kind.Fell_Behind else ifx it.not_recordable then .Not_Recordable else .Said;
			array_add(*sealed, .{kind = kind, at_ms = it.start_ms, end_ms = it.end_ms, speaker = ifx it.dropped_ms then 0 else it.user_id, who = l.who, text = l.text, dropped_ms = it.dropped_ms});
		}
		if !l.text free(it.text);
		t := to_calendar(APOLLO_TIME_FOR_JAN_1_1970 + milliseconds_to_apollo(l.at_ms), .LOCAL);
		print_to_builder(*b, "**%:%:%** %: %\n\n", formatInt(t.hour, minimum_digits = 2), formatInt(t.minute, minimum_digits = 2), formatInt(t.second, minimum_digits = 2),
			ifx l.who then l.who else "—", ifx l.text then l.text else tprint("_%_", l.note));
	}
	if transcript.call transcript_write(vault.write(transcript.call, sealed));
	else if transcript.path && !voice_headless_quiet() stt.append_file(transcript.path, builder_to_string(*b,, temp));
	app.ui.animating = true;
}

transcript_write :: (w: *vault.Write) {
	e2e.submit(e2e_db, w);
	array_add(*transcript.writes, w);
}

// Headless runs (tests, shots) transcribe like a real one but write no file.
voice_headless_quiet :: () -> bool { return platform.is_headless() && env_var("FASTCORD_TRANSCRIBE_TEST") == ""; }

transcript_begin :: (m: *stt.Model) {
	if transcript.active transcript_end();
	transcript.active = true;
	transcript.channel = app.voice_channel;
	stt.configure(stt_model_path(m), m.kind, m.english_only, transcript.everyone, wake = platform.request_frame);
	stt.set_active(true);
	for transcript.lines { free(it.who); free(it.text); free(it.note); }
	transcript.lines.count = 0;
	s := call_store();
	ch := dc.channel_get(s, transcript.channel);
	name := ifx ch && ch.name then ch.name else L("Call");
	t := to_calendar(current_time_consensus(), .LOCAL);
	stamp := tprint("%-%-% %%", t.year, formatInt(t.month_starting_at_0 + 1, minimum_digits = 2), formatInt(t.day_of_month_starting_at_0 + 1, minimum_digits = 2),
		formatInt(t.hour, minimum_digits = 2), formatInt(t.minute, minimum_digits = 2));
	free(transcript.path);
	transcript.path = "";
	if transcript.vault_found {
		g := ifx ch then dc.guild_get(s, ch.guild_id) else null;
		transcript.call = vault.call_start(.{title = name, place = ifx g then g.name else "", model = m.id, started_ms = unix_ms_now()});
		return;
	}
	transcript.path = sprint("%/% %.md", app_data_dir("transcripts"), stamp, file_safe(name));
	if !voice_headless_quiet() stt.append_file(transcript.path, tprint("# %\n\n%\n\n", name, tprint(L("Transcribed on this computer with %."), m.name)));
}

transcript_end :: () {
	transcript.active = false;
	stt.set_active(false);
	if transcript.call {
		NONE: []vault.Line;
		transcript_write(vault.write(transcript.call, NONE, unix_ms_now()));
		transcript.call = null; // Freed once that write is done.
	}
}

unix_ms_now :: () -> s64 { return to_milliseconds(current_time_consensus() - APOLLO_TIME_FOR_JAN_1_1970); }

// file_safe: a channel name as part of a file name on every OS.
file_safe :: (s: string) -> string {
	out := copy_string(slice(s, 0, min(s.count, 80)),, temp);
	for i: 0..out.count-1 {
		c := out[i];
		if c < 0x20 || c == #char "/" || c == #char "\\" || c == #char ":" || c == #char "*" || c == #char "?" || c == #char "\"" || c == #char "<" || c == #char ">" || c == #char "|" out[i] = #char "_";
	}
	return trim(out, " .");
}

// ---- the model's file ----

// model_check_start: on a thread, whether path holds size bytes (and, with sha256, that hash); with part, a
// verified part is renamed to path first.
model_check_start :: (path: string, part: string, size: s64, sha256: string) -> *Model_Check {
	c := New(Model_Check);
	c.path, c.part, c.sha256, c.size = copy_string(path), copy_string(part), copy_string(sha256), size;
	dc.spawn(c, (c: *Model_Check) {
		src := ifx c.part then c.part else c.path;
		ok := false;
		f, opened := file_open(src, log_errors = false);
		if opened {
			n, _ := file_length(f);
			ok = n == c.size;
			if ok && c.sha256 {
				h: crypto.Sha256;
				crypto.sha256_init(*h);
				buf := NewArray(1 << 20, u8);
				left := n;
				while left > 0 && ok {
					k := min(left, buf.count);
					ok = file_read(f, buf.data, k);
					if ok crypto.sha256_update(*h, array_view(buf, 0, k));
					left -= k;
				}
				array_free(buf);
				sum := crypto.sha256_final(*h);
				hex: [64]u8;
				for sum { hex[it_index * 2] = "0123456789abcdef"[it >> 4]; hex[it_index * 2 + 1] = "0123456789abcdef"[it & 15]; }
				ok = ok && cast(string) hex == c.sha256;
			}
			file_close(*f);
		}
		if c.part {
			if ok {
				file_delete(c.path);
				ok = file_move(c.part, c.path);
			}
			if !ok file_delete(c.part);
		}
		c.ok = ok;
		atomic_store(*c.done, true);
		platform.request_frame();
	});
	return c;
}

model_check_free :: (c: *Model_Check) {
	free(c.path); free(c.part); free(c.sha256);
	free(c);
}

stt_download_start :: () {
	if transcript.dl || transcript.verify return;
	m := stt_model();
	cl := ifx app.client && app.client.cfg.hosted.host then app.discord else app.client;
	if !cl return;
	dir := app_data_dir("models");
	make_directory_if_it_does_not_exist(dir, recursive = true);
	free(transcript.dl_id);
	transcript.dl_id = copy_string(m.id);
	transcript.dl_failed = false;
	transcript.dl = New(dc.Media_Progress);
	dc.fetch_media(cl, .{url = m.url, tag = MEDIA_TAG_STT, save_to = tprint("%.part", stt_model_path(m)), progress = transcript.dl, any_host = true});
}

stt_download_receive :: (r: *dc.Media_Result) -> bool {
	if r.tag != MEDIA_TAG_STT return false;
	m := stt_model_find(transcript.dl_id);
	free(transcript.dl);
	transcript.dl = null;
	if !m || r.status != 200 { transcript.dl_failed = true; return true; }
	path := stt_model_path(m);
	transcript.verify = model_check_start(path, tprint("%.part", path), m.size, m.sha256);
	return true;
}

MEDIA_TAG_STT :: 0x6d65_6469_6110;

// ---- the call's pane ----

TRANSCRIPT_PANE_W :: 340;

transcript_pane :: () {
	pane := ui.box("transcript", .Draw_Background | .Clip);
	pane.semantic_size = .[ui.px(TRANSCRIPT_PANE_W), ui.pct(1)];
	pane.layout_axis = .Y;
	pane.style.bg = T("--background-base-lower");
	ui.parent(pane); defer ui.pop_parent();
	head := row("head");
	head.semantic_size = .[ui.pct(1), ui.px(40)];
	{ ui.parent(head); defer ui.pop_parent();
		spacer(.X, 12);
		label(L("Transcript"), .Semibold, 14, T("--text-strong"), 40);
		filler(.X);
		st, backlog := stt.status();
		info := ifx st == .Loading then L("Loading model…") else ifx st == .Failed then L("The model didn't load.") else ifx backlog > 5000 then tprint(L("% s behind"), backlog / 1000) else "";
		if info label(info, .Normal, 12, T("--text-muted"), 40);
		spacer(.X, 12);
	}
	list := ui.box("lines", .Scroll_Y | .Clip);
	list.semantic_size = .[ui.pct(1), ui.fill()];
	list.layout_axis = .Y;
	list.scrollbar = .Thin;
	// It follows new lines while scrolled to the end, as the chat does.
	if list.view_off_target.y >= list.content_size.y - (list.rect.y1 - list.rect.y0) - 2 list.view_off_target.y = 1_000_000_000;
	ui.signal(list);
	ui.parent(list); defer ui.pop_parent();
	if !transcript.lines.count {
		spacer(.Y, 12);
		r := row("empty");
		r.semantic_size = .[ui.pct(1), ui.px(18)];
		ui.parent(r); defer ui.pop_parent();
		spacer(.X, 12);
		label(L("What people say will appear here."), .Normal, 13, T("--text-muted"), 18);
	}
	for transcript.lines {
		item := ui.box(tprint("line%", it_index));
		item.semantic_size = .[ui.pct(1), ui.children()];
		item.layout_axis = .Y;
		item.style.padding = .{12, 6};
		ui.parent(item); defer ui.pop_parent();
		t := to_calendar(APOLLO_TIME_FOR_JAN_1_1970 + milliseconds_to_apollo(it.at_ms), .LOCAL);
		if it.who {
			wrap("who", tprint("%  %:%", it.who, formatInt(t.hour, minimum_digits = 2), formatInt(t.minute, minimum_digits = 2)), .Semibold, 13, T("--text-strong"));
		}
		if it.text wrap("text", it.text, .Normal, 14, T("--text-default"));
		else wrap("note", it.note, .Normal, 13, T("--text-muted"));
	}
}
