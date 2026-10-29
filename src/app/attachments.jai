// Staged attachments in the composer, like the official client:
//   - files come from the "+" picker, drag and drop (with the "Upload to #channel" overlay)
//     and Cmd/Ctrl+V (file URLs copied in Finder / Explorer, or a bitmap staged as image.png);
//   - each file is read, measured and thumbnailed on a worker thread, then starts uploading at
//     once (dc.upload_draft: the client uploads on staging, traffic/upload_options.jsonl);
//   - cards above the text area: thumbnail (image / video poster / file icon), filename, and
//     an action bar: Spoiler (eye), Modify (pencil: filename, alt text, spoiler), Remove (trash);
//   - limits: 10 files, and the upload size of the user's plan / the server's boost level,
//     shown as the client's "too powerful" / "too many uploads" notices.

MAX_ATTACHMENTS :: 10;
MB :: 1024 * 1024;

Att_Kind :: enum u8 {
	Other;
	Image;
	Video;
}

Staged :: struct {
	key: u64; // stable UI id
	loading: bool; // the worker is still reading / decoding it
	path: string; // source file ("" for a pasted bitmap)
	filename: string; // display name (renamed in Modify)
	description: string; // alt text
	spoiler: bool;
	mime: string;
	size: s64;
	kind: Att_Kind;
	origin: string; // science origin of the upload
	draft: u64; // dc.upload_draft handle (0 offline)
	thumb: gfx.Texture;
	blur: gfx.Texture; // a tiny copy, drawn stretched: the spoiler blur
	thumb_size: Int2;
	data: []u8; // videos keep their bytes for the poster player
	player: *media.Player;
	poster: media.Video_Image;
}

Att_Notice :: enum u8 {
	None;
	Too_Large;
	Too_Many;
}

Att_State :: struct {
	by_channel: Table(dc.Snowflake, [..]Staged); // the client keeps a draft per channel
	next_key: u64;
	// workers (UI thread only) and their results
	threads: [..]*Thread;
	mu: locks.Mutex;
	results: [..]Att_Result;
	// overlays
	notice: Att_Notice;
	drag: bool; // files dragged over the window
	// Modify modal
	mod_channel: dc.Snowflake;
	mod_key: u64; // 0 = closed
	mod_name: ui.Editor;
	mod_desc: ui.Editor;
	mod_spoiler: bool;
	mod_focus: int; // 0 filename, 1 description
	// sent messages still uploading: nonce -> what they carry
	sending: Table(dc.Snowflake, Att_Sending);
	limit_override: s64; // UI scripts: a small limit to show the too-large notice
}

Att_Sending :: struct {
	channel: dc.Snowflake;
	drafts: []u64;
	names: []string;
	total: s64;
}

att: Att_State;

// ---- pure helpers (unit tested) ----

// Upload size limit in bytes: the user's plan (none 10 MB, Basic / Classic 50 MB, Nitro 500 MB)
// or the server's boost level (tier 2: 50 MB, tier 3: 100 MB), whichever is larger.
upload_limit :: (premium_type: int, guild_tier: int) -> s64 {
	user: s64 = 10 * MB;
	if premium_type == {
	case 1; #through; case 3;
		user = 50 * MB;
	case 2;
		user = 500 * MB;
	}
	guild: s64 = 10 * MB;
	if guild_tier == 2 guild = 50 * MB;
	if guild_tier >= 3 guild = 100 * MB;
	return max(user, guild);
}

channel_upload_limit :: (channel_id: dc.Snowflake) -> s64 {
	if att.limit_override > 0 return att.limit_override;
	s := store();
	premium, tier := 0, 0;
	u := dc.user_get(s, s.me);
	if u premium = u.premium_type;
	ch := dc.channel_get(s, channel_id);
	if ch && ch.guild_id {
		g := table_find_pointer(*s.guilds, ch.guild_id);
		if g tier = g.premium_tier;
	}
	return upload_limit(premium, tier);
}

// "Max file size is 10 MB please."
limit_text :: (limit: s64) -> string {
	if limit % MB == 0 return tprint("Max file size is % MB please.", limit / MB);
	return tprint("Max file size is % MB please.", formatFloat(cast(float64) limit / MB, trailing_width = 2, zero_removal = .NO));
}

// Would adding n files go over the cap? (the client rejects the whole batch)
too_many_files :: (have: int, adding: int) -> bool { return have + adding > MAX_ATTACHMENTS; }

att_kind_of :: (mime: string) -> Att_Kind {
	if begins_with(mime, "image/") return .Image;
	if begins_with(mime, "video/") return .Video;
	return .Other;
}

// File-type icon for a card without a thumbnail.
file_icon_for :: (name: string) -> string {
	ext := path_base(name);
	dot := find_index_from_right(ext, #char ".");
	if dot < 0 ext = ""; else advance(*ext, dot);
	if to_lower_copy(ext,, temp) == {
	case ".mp4"; #through; case ".mov"; #through; case ".webm"; #through; case ".mkv"; #through; case ".avi";
		return "video";
	case ".mp3"; #through; case ".ogg"; #through; case ".wav"; #through; case ".flac"; #through; case ".m4a"; #through; case ".opus";
		return "music";
	case ".png"; #through; case ".jpg"; #through; case ".jpeg"; #through; case ".gif"; #through; case ".webp"; #through; case ".bmp"; #through; case ".heic";
		return "image-file";
	case ".txt"; #through; case ".md"; #through; case ".pdf"; #through; case ".doc"; #through; case ".docx"; #through; case ".rtf";
		return "paper";
	case ".odin"; #through; case ".c"; #through; case ".h"; #through; case ".py"; #through; case ".js"; #through; case ".ts"; #through; case ".go"; #through; case ".rs"; #through; case ".json"; #through; case ".html"; #through; case ".css"; #through; case ".sh";
		return "angle-brackets";
	}
	return "file";
}

// A filename the user typed in Modify: no path separators, never empty.
clean_filename :: (name: string, fallback: string) -> string {
	n := replace(trim(name, SPACES), "/", "_",, temp);
	n = replace(n, "\\", "_",, temp);
	return ifx n then n else fallback;
}

// Box-filter downscale to fit max_side (no upscale). Returns RGBA.
downscale :: (px: []u8, w: int, h: int, max_side: int) -> []u8, int, int {
	sc := min(cast(float64) 1, cast(float64) max_side / cast(float64) max(w, h));
	ow := max(1, cast(int) (cast(float64) w * sc + 0.5));
	oh := max(1, cast(int) (cast(float64) h * sc + 0.5));
	out := NewArray(ow * oh * 4, u8);
	for y: 0..oh-1 {
		y0 := y * h / oh;
		y1 := max(y0 + 1, (y + 1) * h / oh);
		for x: 0..ow-1 {
			x0 := x * w / ow;
			x1 := max(x0 + 1, (x + 1) * w / ow);
			// at most 4x4 samples per output pixel
			sy := max(1, (y1 - y0) / 4);
			sx := max(1, (x1 - x0) / 4);
			acc: [4]int;
			n := 0;
			iy := y0;
			while iy < y1 {
				ix := x0;
				while ix < x1 {
					for c: 0..3 acc[c] += px[(iy * w + ix) * 4 + c];
					n += 1;
					ix += sx;
				}
				iy += sy;
			}
			for c: 0..3 out[(y * ow + x) * 4 + c] = cast(u8) (acc[c] / n);
		}
	}
	return out, ow, oh;
}

// ---- worker ----

Att_Job_Kind :: enum u8 {
	File;
	Paste_Image;
	Paste_Files;
}

Att_Error :: enum u8 {
	None;
	Read_Failed;
	Too_Large;
	Empty;
}

Att_Result :: struct {
	kind: Att_Job_Kind;
	key: u64;
	channel: dc.Snowflake;
	err: Att_Error;
	data: []u8;
	size: s64;
	thumb: []u8;
	tw, th: int;
	blur: []u8;
	bw, bh: int;
	paths: []string; // Paste_Files: the clipboard's files
}
// Jobs still running (tests wait for them).
attachments_busy :: () -> bool {
	for att.threads if !thread_is_done(it) return true;
	locks.lock(*att.mu);
	defer locks.unlock(*att.mu);
	return att.results.count > 0;
}

// ---- staging ----

staged_list :: (channel_id: dc.Snowflake) -> *[..]Staged { return find_or_add(*att.by_channel, channel_id); }

staged_count :: (channel_id: dc.Snowflake) -> int {
	l := table_find_pointer(*att.by_channel, channel_id);
	return ifx l then l.count else 0;
}

// Files from the picker, a drop or a paste: one loading card each, read on a worker.
stage_paths :: (channel_id: dc.Snowflake, paths: []string, origin: string) {
	if channel_id == 0 || !paths return;
	l := staged_list(channel_id);
	if too_many_files(l.count, paths.count) {
		att.notice = .Too_Many;
		return;
	}
	limit := channel_upload_limit(channel_id);
	for p: paths {
		att.next_key += 1;
		name := path_base(p);
		mime := mime_for(name);
		array_add(l, .{key = att.next_key, loading = true, path = copy_string(p), filename = copy_string(name), mime = copy_string(mime), kind = att_kind_of(mime), origin = origin});
		att_spawn(.{kind = .File, key = att.next_key, channel = channel_id, path = p, mime = mime, limit = limit});
	}
}

// Cmd/Ctrl+V in the composer: files or a bitmap on the clipboard are staged (true: handled);
// otherwise the text field pastes text.
paste_attachments :: (channel_id: dc.Snowflake) -> bool {
	kind := platform.clipboard_kind();
	if kind == {
	case .Files;
		att_spawn(.{kind = .Paste_Files, channel = channel_id});
		return true;
	case .Image;
		if too_many_files(staged_count(channel_id), 1) {
			att.notice = .Too_Many;
			return true;
		}
		att_spawn(.{kind = .Paste_Image, channel = channel_id, mime = "image/png", limit = channel_upload_limit(channel_id)});
		return true;
	case .Text; #through; case .None;
	}
	return false;
}

// Remove (trash): the uploaded file is deleted from the bucket too.
staged_remove :: (channel_id: dc.Snowflake, key: u64) {
	l := staged_list(channel_id);
	for * u, i: l.* {
		if u.key != key continue;
		if u.draft && app.client dc.upload_draft_remove(app.client, u.draft);
		staged_free(u);
		array_ordered_remove_by_index(l, i);
		return;
	}
}

staged_find :: (channel_id: dc.Snowflake, key: u64) -> *Staged {
	l := table_find_pointer(*att.by_channel, channel_id);
	if l for * l.* if it.key == key return it;
	return null;
}

// Per frame: worker results become cards (and uploads), video posters load.
attachments_frame :: () {
	for att.threads if thread_is_done(it) {
		thread_deinit(it);
		free(it);
		remove it;
	}
	locks.lock(*att.mu);
	results := array_copy(att.results,, temp);
	att.results.count = 0;
	locks.unlock(*att.mu);
	for * r: results {
		defer {
			free(r.thumb.data);
			free(r.blur.data);
			for r.paths free(it);
			free(r.paths.data);
		}
		if r.kind == {
		case .Paste_Files;
			if r.paths stage_paths(r.channel, r.paths, "clipboard");
			continue;
		case .Paste_Image;
			if r.err == .Too_Large {
				att.notice = .Too_Large;
				continue;
			}
			if r.err != .None continue;
			l := staged_list(r.channel);
			if too_many_files(l.count, 1) {
				att.notice = .Too_Many;
				free(r.data.data);
				continue;
			}
			att.next_key += 1;
			// the name Chromium gives a pasted bitmap
			array_add(l, .{key = att.next_key, loading = true, filename = copy_string("image.png"), mime = copy_string("image/png"), kind = .Image, origin = "clipboard"});
			r.key = att.next_key;
		case .File;
		}
		u := staged_find(r.channel, r.key);
		if u == null {
			free(r.data.data); // removed while loading
			continue;
		}
		if r.err != .None {
			if r.err == .Too_Large att.notice = .Too_Large;
			staged_remove(r.channel, r.key);
			free(r.data.data);
			continue;
		}
		u.loading = false;
		u.size = r.size;
		if r.thumb {
			u.thumb = gfx.texture_from_rgba(r.tw, r.th, r.thumb);
			u.thumb_size = .{r.tw, r.th};
			u.blur = gfx.texture_from_rgba(r.bw, r.bh, r.blur);
		}
		if app.client u.draft = dc.upload_draft(app.client, r.channel, u.filename, u.mime, r.data, u.origin);
		if u.kind == .Video {
			u.data = r.data; // the poster player reads it in place
			ensure_audio();
			u.player = media.player_open(media.source_from_memory(u.data), autoplay = false, muted = true);
		} else {
			free(r.data.data);
		}
		app.ui.animating = true;
	}
	// video posters: the player decodes its first frame on its own thread
	for * l: att.by_channel {
		for * u: l.* {
			if !u.player || u.poster.y != 0 continue;
			img := media.player_update(u.player);
			if img.y != 0 u.poster = img;
			else if media.player_state(u.player) != .Error request_wake(app.ui.time + 0.05);
		}
	}
	// sent messages: forget the ones that landed
	for sn, nonce: att.sending {
		done := true;
		for sn.drafts {
			st, _, _, ok := dc.upload_draft_status(app.client, it);
			if ok && st == .Uploading done = false;
		}
		if done {
			sending_free(sn);
			table_remove(*att.sending, nonce);
		}
	}
}

// Send: the composer's staged files go with the message (they are already uploading).
// Returns false while a file is still being read.
attachments_for_send :: (channel_id: dc.Snowflake) -> []dc.Draft_Attachment, bool {
	l := table_find_pointer(*att.by_channel, channel_id);
	if !l || !l.count return .[], true;
	out := NewArray(l.count, dc.Draft_Attachment,, temp);
	for l.* {
		if it.loading return .[], false;
		out[it_index] = .{handle = it.draft, filename = it.filename, description = it.description, spoiler = it.spoiler};
	}
	return out, true;
}

// After send: remember what the pending message uploads (its progress bar), clear the cards
// without deleting the uploads (they now belong to the message).
attachments_sent :: (channel_id: dc.Snowflake, nonce: dc.Snowflake) {
	l := table_find_pointer(*att.by_channel, channel_id);
	if !l return;
	if nonce && l.count {
		sn := Att_Sending.{channel = channel_id, drafts = NewArray(l.count, u64), names = NewArray(l.count, string)};
		for l.* {
			sn.drafts[it_index] = it.draft;
			sn.names[it_index] = copy_string(it.filename);
			sn.total += it.size;
		}
		table_set(*att.sending, nonce, sn);
	}
	for * l.* staged_free(it);
	l.count = 0;
}

attachments_modal_open :: () -> bool { return att.mod_key != 0 || att.notice != .None; }

// ---- cards ----

CARD :: 200;
CARD_PAD :: 8;
CARD_IMG_H :: 156;
BAR_BTN :: 32;

// The row of staged cards above the text area (horizontally scrollable).
uploads_bar :: (channel_id: dc.Snowflake) {
	l := table_find_pointer(*att.by_channel, channel_id);
	if !l || !l.count return;
	bar := row("uploads", .Scroll_X | .Clip);
	bar.semantic_size = .[ui.pct(1), ui.px(20 + CARD + 10)];
	bar.cross_align = .Start;
	// a vertical wheel scrolls the row sideways, like the client's overflow-x area
	for * e: app.ui.events {
		if e.kind == .Scroll && !e.consumed && e.delta.x == 0 && rect_has(ui.visible_rect(bar), app.ui.mouse) {
			bar.view_off_target.x -= e.delta.y;
			e.consumed = true;
		}
	}
	ui.signal(bar);
	remove_: u64;
	{ ui.parent(bar); defer ui.pop_parent();
		spacer(.X, 10);
		for * l.* {
			if it_index > 0 spacer(.X, 24);
			if staged_card(channel_id, it) remove_ = it.key;
		}
		spacer(.X, 10);
	}
	if remove_ staged_remove(channel_id, remove_);
	sep := ui.box("upsep", .Draw_Background);
	sep.semantic_size = .[ui.pct(1), ui.px(1)];
	sep.style.bg = T("--border-subtle");
}

// A sent message whose files are still uploading: the client shows it pending with a progress bar.
upload_progress_view :: (m: *dc.Message) {
	sn := table_find_pointer(*att.sending, m.id);
	if !sn || !app.client return;
	sent: s64;
	for sn.drafts {
		_, s, _, ok := dc.upload_draft_status(app.client, it);
		if ok sent += s;
	}
	f := row("uploading", .Draw_Background | .Draw_Border);
	f.semantic_size = .[ui.px(432), ui.px(72)];
	f.style.bg = T("--background-surface-high");
	f.style.border_color = T("--border-subtle");
	f.style.border = 1;
	f.style.radius = all4(8);
	{ ui.parent(f); defer ui.pop_parent();
		spacer(.X, 16);
		icon("ficon", file_icon_for(sn.names[0]), 30, T("--interactive-icon-default"));
		spacer(.X, 8);
		col := ui.box("col");
		col.semantic_size = .[ui.fill(), ui.children()];
		col.layout_axis = .Y;
		{ ui.parent(col); defer ui.pop_parent();
			name := ifx sn.names.count == 1 then sn.names[0] else tprint("% files", sn.names.count);
			label(tprint("%##upname", name), .Normal, 16, T("--text-default"), 20);
			spacer(.Y, 6);
			track := ui.box("track", .Draw_Background);
			track.semantic_size = .[ui.pct(1), ui.px(6)];
			track.style.bg = T("--background-mod-strong");
			track.style.radius = all4(3);
			{ ui.parent(track); defer ui.pop_parent();
				frac := ifx sn.total > 0 then cast(float32) sent / cast(float32) sn.total else 0;
				fill := ui.box("fill", .Draw_Background);
				fill.semantic_size = .[ui.pct(max(0.05, frac)), ui.px(6)];
				fill.style.bg = T("--background-brand");
				fill.style.radius = all4(3);
			}
		}
		spacer(.X, 16);
	}
	spacer(.Y, 4);
	request_wake(app.ui.time + 0.1);
}

// ---- Modify modal ----

modify_open :: (channel_id: dc.Snowflake, u: *Staged) {
	att.mod_channel = channel_id;
	att.mod_key = u.key;
	att.mod_spoiler = u.spoiler;
	att.mod_focus = 0;
	ui.editor_set_text(*att.mod_name, u.filename);
	ui.editor_set_text(*att.mod_desc, u.description);
}

modify_modal :: () {
	u := staged_find(att.mod_channel, att.mod_key);
	if u == null {
		att.mod_key = 0;
		return;
	}
	scrim := ui.box("mod_scrim", .Draw_Background | .Clickable | .Floating_X | .Floating_Y | .Overlay);
	scrim.semantic_size = .[ui.px(app.ui.window.x), ui.px(app.ui.window.y)];
	scrim.style.bg = .{0, 0, 0, 0.7};
	if ui.signal(scrim).clicked {
		att.mod_key = 0;
		return;
	}
	W :: 440;
	PAD :: 24;
	d := ui.box("modmodal", .Draw_Background | .Draw_Border | .Floating_X | .Floating_Y | .Overlay | .Clickable);
	d.semantic_size = .[ui.px(W), ui.children()];
	d.fixed_pos = .{(app.ui.window.x - W) / 2, (app.ui.window.y - (d.rect.y1 - d.rect.y0)) / 2};
	d.style.bg = T("--modal-background");
	d.style.border_color = T("--border-subtle");
	d.style.border = 1;
	d.style.radius = all4(12);
	d.layout_axis = .Y;
	ui.signal(d);
	ui.push_parent(d);
	defer ui.pop_parent();
	text_row :: (id: string, text: string, font: Font_Id, size: float32, lh: float32, color: ui.Color) {
		r := row(id);
		r.semantic_size = .[ui.pct(1), ui.px(lh)];
		{ ui.parent(r); defer ui.pop_parent();
			spacer(.X, PAD);
			label(text, font, size, color, lh);
		}
	}
	save, cancel := false, false;
	field :: (id: string, ed: *ui.Editor, placeholder: string, idx: int) -> ui.Edit_Result {
		res := ui.Edit_Result.None;
		ir := row(id);
		ir.semantic_size = .[ui.pct(1), ui.px(40)];
		{ ui.parent(ir); defer ui.pop_parent();
			spacer(.X, PAD);
			box := row("input", .Draw_Background | .Draw_Border | .Clickable);
			box.semantic_size = .[ui.fill(), ui.px(40)];
			box.style.bg = T("--input-background-default");
			box.style.border_color = ifx att.mod_focus == idx then T("--input-border-active") else T("--input-border-default");
			box.style.border = 1;
			box.style.radius = all4(8);
			box.hover_cursor = .IBeam;
			if ui.signal(box).pressed att.mod_focus = idx;
			{ ui.parent(box); defer ui.pop_parent();
				spacer(.X, 12);
				before := app.ui.focus;
				res = text_field("field", ed, placeholder, att.mod_focus == idx, 16, 20, 10, T("--input-placeholder-text-default"));
				// a press on the text itself focuses the container (text_field)
				if app.ui.focus != before && app.ui.focus == box.key att.mod_focus = idx;
				spacer(.X, 12);
			}
			spacer(.X, PAD);
		}
		return res;
	}
	spacer(.Y, PAD);
	text_row("t", tprint("%##modtitle", ellipsize(u.filename, .Semibold, 20, W - 2 * PAD)), .Semibold, 20, 24, T("--text-strong"));
	spacer(.Y, 20);
	text_row("lname", "Filename", .Medium, 14, 18, T("--text-strong"));
	spacer(.Y, 8);
	r1 := field("namerow", *att.mod_name, "", 0);
	spacer(.Y, 16);
	text_row("ldesc", "Description (alt text)", .Medium, 14, 18, T("--text-strong"));
	spacer(.Y, 8);
	r2 := field("descrow", *att.mod_desc, "Add a description", 1);
	for r: (ui.Edit_Result.[r1, r2]) {
		if r == .Submit save = true;
		if r == .Escape cancel = true;
	}
	spacer(.Y, 16);
	cr := row("spoilerrow", .Clickable);
	cr.semantic_size = .[ui.pct(1), ui.px(24)];
	if ui.signal(cr).clicked att.mod_spoiler = !att.mod_spoiler;
	{ ui.parent(cr); defer ui.pop_parent();
		spacer(.X, PAD);
		cb := ui.box("check", .Draw_Background | .Draw_Border);
		cb.semantic_size = .[ui.px(20), ui.px(20)];
		cb.style.radius = all4(6);
		cb.style.border = ifx att.mod_spoiler then 0.0 else 1.0;
		cb.style.border_color = T("--checkbox-border-default");
		cb.style.bg = ifx att.mod_spoiler then T("--background-brand") else .{};
		if att.mod_spoiler {
			{ ui.parent(cb); defer ui.pop_parent();
				i := ui.box("i", .Floating_X | .Floating_Y);
				i.semantic_size = .[ui.px(18), ui.px(18)];
				i.fixed_pos = .{1, 1};
				set_icon(i, "checkmark-small", .{1, 1, 1, 1});
			}
		}
		spacer(.X, 8);
		label("Mark as spoiler", .Normal, 16, T("--text-default"), 20);
	}
	spacer(.Y, PAD);
	btns := row("btns", .Draw_Background);
	btns.semantic_size = .[ui.pct(1), ui.px(70)];
	btns.style.bg = T("--background-base-lower");
	btns.style.radius = .[0, 0, 12, 12];
	btns.style.child_gap = 8;
	button :: (id: string, w: float32, bg: ui.Color, bg_hot: ui.Color, fg: ui.Color) -> bool {
		b := ui.box(id, .Clickable | .Draw_Background | .Draw_Text | .Hot_Animation);
		b.semantic_size = .[ui.px(w), ui.px(38)];
		b.style.radius = all4(8);
		b.style.font = F(.Medium);
		b.style.font_size = 14;
		b.style.text_align = .Center;
		b.style.text_color = fg;
		b.style.bg = bg;
		b.style.bg_hot = bg_hot;
		return ui.signal(b).clicked;
	}
	{ ui.parent(btns); defer ui.pop_parent();
		filler(.X);
		if button("Cancel##modcancel", 96, T("--background-mod-normal"), T("--background-mod-strong"), T("--text-strong")) cancel = true;
		if button("Save##modsave", 96, T("--background-brand"), with_alpha(T("--background-brand"), 0.85), .{1, 1, 1, 1}) { save = true; }
		spacer(.X, PAD - 8);
	}
	for * e: app.ui.events {
		if e.consumed || e.kind != .Key_Down continue;
		if e.key == .Escape {
			e.consumed = true;
			cancel = true;
		} else if e.key == .Tab {
			e.consumed = true;
			att.mod_focus = 1 - att.mod_focus;
		}
	}
	if save { modify_save(u); } else if cancel { att.mod_key = 0; }
	if att.mod_key == 0 { app.ui.focus = 0; } // back to the composer, like the client
}

// ---- overlays: drag target, limit notices ----

attachments_overlays :: () {
	if att.mod_key != 0 modify_modal();
	ch := dc.channel_get(store(), app.view.channel);
	if att.notice != .None {
		title, line: string;
		if att.notice == {
		case .Too_Large;
			title = "Your files are too powerful";
			line = limit_text(channel_upload_limit(app.view.channel));
		case .Too_Many;
			title = "Too many uploads!";
			line = tprint("You can only upload % files at a time!", MAX_ATTACHMENTS);
		}
		if upload_card_overlay("att_notice", title, line, T("--status-danger"), "file-warning", true) att.notice = .None;
		for * e: app.ui.events {
			if !e.consumed && e.kind == .Key_Down && e.key == .Escape {
				e.consumed = true;
				att.notice = .None;
			}
		}
	} else if att.drag && ch != null && !server_settings_is_open() {
		where_ := ifx ch.kind == .DM then tprint("@%", dm_name(ch)) else ifx ch.kind == .Group_DM then dm_name(ch) else tprint("#%", ch.name);
		upload_card_overlay("att_drag", tprint("Upload to %", where_), "You can add comments before uploading.\nHold shift to upload directly.", T("--background-brand"), "file-up", false);
	}
}

// Platform drag events (main loop).
attachments_drag_event :: (e: platform.Event) {
	if e.kind == {
	case .Drag_Enter;
		att.drag = true;
	case .Drag_Leave;
		att.drag = false;
	}
}

// Sweep: back to no staged files (waits for in-flight reads first).
attachments_reset_for_test :: () {
	while attachments_busy() {
		attachments_frame();
		sleep_milliseconds(1);
	}
	for att.threads {
		thread_deinit(it);
		free(it);
	}
	array_free(att.threads);
	for * l: att.by_channel {
		for * l.* staged_free(it);
		array_free(l.*);
	}
	deinit(*att.by_channel);
	for att.sending sending_free(it);
	deinit(*att.sending);
	array_free(att.results);
	ui.editor_set_text(*att.mod_name, "");
	ui.editor_set_text(*att.mod_desc, "");
	name, desc := att.mod_name, att.mod_desc;
	att = .{};
	att.mod_name, att.mod_desc = name, desc;
}

#scope_file

Att_Job :: struct {
	kind: Att_Job_Kind;
	key: u64;
	channel: dc.Snowflake;
	path: string;
	mime: string;
	limit: s64;
}

// A worker's Jai *Thread (local.jai's fc Thread alias hides the name for now).

// The worker owns copies of the job's strings.
att_spawn :: (j: Att_Job) {
	job := j;
	job.path = copy_string(j.path);
	job.mime = copy_string(j.mime);
	array_add(*att.threads, dc.spawn(job, att_work));
}

att_work :: (j: Att_Job) {
	res := Att_Result.{kind = j.kind, key = j.key, channel = j.channel};
	if j.kind == {
	case .Paste_Files;
		res.paths = platform.clipboard_files();
	case .Paste_Image;
		png, ok := platform.clipboard_image();
		if ok res.data = png; else res.err = .Empty;
	case .File;
		res.err = read_file(j.path, j.limit, *res);
	}
	if j.kind != .Paste_Files && res.err == .None {
		res.size = res.data.count;
		if res.size > j.limit {
			res.err = .Too_Large;
			free(res.data.data);
			res.data = .[];
		} else if begins_with(j.mime, "image/") || j.kind == .Paste_Image {
			// thumbnail off the UI thread: 400 px (the 184x156 card area at 2x), plus a
			// 12 px copy drawn stretched as the spoiler blur
			img, err := imagefmt.decode_first_frame(res.data, temp, 64 << 20);
			if err == .None && img.frames {
				res.thumb, res.tw, res.th = downscale(img.frames[0].pixels, img.width, img.height, 400);
				res.blur, res.bw, res.bh = downscale(res.thumb, res.tw, res.th, 12);
			}
		}
	}
	locks.lock(*att.mu);
	array_add(*att.results, res);
	locks.unlock(*att.mu);
	free(j.path);
	free(j.mime);
	reset_temporary_storage();
	platform.request_frame();
}

// A file's bytes, unless it is over the limit (then only its size).
read_file :: (path: string, limit: s64, res: *Att_Result) -> Att_Error {
	f, ok := file_open(path, log_errors = false);
	if !ok return .Read_Failed;
	defer file_close(*f);
	size, sized := file_length(f);
	if !sized return .Read_Failed;
	if size > limit {
		res.size = size;
		return .Too_Large;
	}
	if size == 0 return .None; // read_entire_file fails on an empty file (alloc(0) is null)
	data, read := read_entire_file(f);
	if !read return .Read_Failed;
	res.data = cast([]u8) data;
	return .None;
}

#if OS == .WINDOWS PATH_SEPS :: "/\\"; else PATH_SEPS :: "/";

path_base :: (p: string) -> string {
	b := p;
	advance(*b, find_index_of_any_from_right(p, PATH_SEPS) + 1);
	return b;
}

// Odin's strings.trim_space set.
SPACES :: " \t\n\r\x0b\x0c";

sending_free :: (sn: Att_Sending) {
	free(sn.drafts.data);
	for sn.names free(it);
	free(sn.names.data);
}

staged_free :: (u: *Staged) {
	if u.player media.player_destroy(u.player);
	if u.thumb gfx.texture_destroy(u.thumb);
	if u.blur gfx.texture_destroy(u.blur);
	free(u.path);
	free(u.filename);
	free(u.description);
	free(u.mime);
	free(u.data.data);
}

Thumb_Draw :: struct {
	tex: gfx.Texture;
	size: Int2;
	video: media.Video_Image;
	blurred: bool;
}

// Draws the thumbnail "contain"-fitted (images, video posters); the spoiler draws the tiny copy stretched.
thumb_draw :: (b: *ui.Box, user: *void) {
	d := cast(*Thumb_Draw)(user);
	r := cast,force(gfx.Rect)(b.rect);
	bw, bh := r.x1 - r.x0, r.y1 - r.y0;
	size := d.size;
	if d.video.y != 0 { size = .{d.video.size[0], d.video.size[1]}; }
	if size.x <= 0 || size.y <= 0 return;
	if d.blurred {
		// cover the whole area, blurry
		white := gfx.Color.{1, 1, 1, b.opacity};
		gfx.push_rect(.{dst = r, tex = d.tex, colors = .[white, white, white, white], radii = b.style.radius});
		return;
	}
	sc := min(bw / cast(float32) size.x, bh / cast(float32) size.y);
	w, h := cast(float32) size.x * sc, cast(float32) size.y * sc;
	x0, y0 := r.x0 + (bw - w) / 2, r.y0 + (bh - h) / 2;
	dst := gfx.Rect.{x0, y0, x0 + w, y0 + h};
	if d.video.y != 0 {
		gfx.video(dst, d.video.y, d.video.cbcr, d.video.yuv, 3);
		return;
	}
	white := gfx.Color.{1, 1, 1, b.opacity};
	gfx.push_rect(.{dst = dst, tex = d.tex, colors = .[white, white, white, white], radii = .[3, 3, 3, 3]});
}

// One card; true when Remove was clicked.
staged_card :: (channel_id: dc.Snowflake, u: *Staged) -> bool {
	removed: bool;
	col := ui.box(tprint("upc%", u.key));
	col.semantic_size = .[ui.px(CARD), ui.px(20 + CARD)];
	col.layout_axis = .Y;
	ui.push_parent(col);
	defer ui.pop_parent();
	spacer(.Y, 20); // room for the action bar riding over the corner
	card := ui.box("card", .Draw_Background);
	card.semantic_size = .[ui.px(CARD), ui.px(CARD)];
	card.style.bg = T("--background-base-low");
	card.style.radius = all4(4);
	card.layout_axis = .Y;
	{ ui.parent(card); defer ui.pop_parent();
		spacer(.Y, CARD_PAD);
		r := row("imgrow");
		r.semantic_size = .[ui.pct(1), ui.px(CARD_IMG_H)];
		{ ui.parent(r); defer ui.pop_parent();
			spacer(.X, CARD_PAD);
			area := ui.box("img", .Clip);
			area.semantic_size = .[ui.px(CARD - 2 * CARD_PAD), ui.px(CARD_IMG_H)];
			area.style.radius = all4(3);
			area.layout_axis = .Y;
			area.cross_align = .Center;
			has_thumb := u.thumb != 0 || u.poster.y != 0;
			if has_thumb {
				d := New(Thumb_Draw,, temp);
				d.* = .{tex = u.thumb, size = u.thumb_size, video = u.poster};
				if u.spoiler {
					d.tex = u.blur;
					d.video = .{};
					d.blurred = true;
				}
				area.custom_draw = thumb_draw;
				area.custom_user = d;
			}
			{ ui.parent(area); defer ui.pop_parent();
				if !has_thumb || (u.spoiler && u.blur == 0) {
					spacer(.Y, (CARD_IMG_H - 64) / 2);
					icon("ficon", file_icon_for(u.filename), 64, T("--interactive-icon-default"));
				}
				if u.spoiler spoiler_pill();
				if u.draft != 0 upload_progress_line(u);
			}
		}
		spacer(.Y, CARD_PAD);
		nr := row("name");
		nr.semantic_size = .[ui.pct(1), ui.px(20)];
		{ ui.parent(nr); defer ui.pop_parent();
			spacer(.X, CARD_PAD);
			label(tprint("%##fname", ellipsize(u.filename, .Normal, 14, CARD - 2 * CARD_PAD)), .Normal, 14, T("--text-default"), 20);
		}
	}
	// action bar over the top-right corner (translate(25%, -25%) in the client's CSS)
	W :: 3 * BAR_BTN + 2 * 4;
	H :: BAR_BTN + 2 * 4;
	ab := row("actions", .Draw_Background | .Draw_Border | .Draw_Shadow | .Floating_X | .Floating_Y);
	ab.semantic_size = .[ui.px(W), ui.px(H)];
	ab.fixed_pos = .{CARD - W * 0.75, 20 - H * 0.25 - 4};
	ab.style.bg = T("--background-surface-higher");
	ab.style.border_color = T("--border-subtle");
	ab.style.border = 1;
	ab.style.radius = all4(8);
	ab.style.shadow_color = .{0, 0, 0, 0.16};
	ab.style.shadow_blur = 4;
	ui.signal(ab);
	{ ui.parent(ab); defer ui.pop_parent();
		spacer(.X, 4);
		Btn :: struct {
			id, icon, tip: string;
			danger: bool;
		}
		btns := Btn.[
			.{"spoiler", ifx u.spoiler then "eye-slash" else "eye", ifx u.spoiler then "Remove Spoiler" else "Spoiler Attachment", false},
			.{"modify", "pencil", "Modify Attachment", false},
			.{"remove", "trash", "Remove Attachment", true}
		];
		for bt: btns {
			b := ui.box(bt.id, .Clickable | .Draw_Background | .Hot_Animation);
			b.semantic_size = .[ui.px(BAR_BTN), ui.px(BAR_BTN)];
			b.style.radius = all4(6);
			b.style.bg_hot = T("--background-mod-subtle");
			b.layout_axis = .X;
			b.cross_align = .Center;
			sig := ui.signal(b);
			{ ui.parent(b); defer ui.pop_parent();
				spacer(.X, 6);
				c := ifx sig.hovering then T("--interactive-icon-hover") else T("--interactive-icon-default");
				if bt.danger c = T("--status-danger");
				icon("i", bt.icon, 20, c);
			}
			if sig.hovering tooltip_below(bt.tip, b.rect);
			if sig.clicked {
				if bt.id == {
				case "spoiler";
					u.spoiler = !u.spoiler;
					if app.client != null dc.analytics_media_draft_edited(app.client, "spoilered", u.spoiler);
				case "modify";
					modify_open(channel_id, u);
				case "remove";
					removed = true;
				}
			}
		}
	}
	return removed;
}

spoiler_pill :: () {
	W :: 74;
	p := row("spoiler", .Draw_Background | .Floating_X | .Floating_Y);
	p.semantic_size = .[ui.px(W), ui.px(24)];
	p.fixed_pos = .{(CARD - 2 * CARD_PAD - W) / 2, (CARD_IMG_H - 24) / 2};
	p.style.bg = .{0, 0, 0, 0.6};
	p.style.radius = all4(12);
	{ ui.parent(p); defer ui.pop_parent();
		spacer(.X, 12);
		label("SPOILER", .Bold, 12, .{1, 1, 1, 1}, 16);
	}
}

// Thin bar along the bottom of the thumbnail while the staged file uploads.
upload_progress_line :: (u: *Staged) {
	st, sent, total, ok := dc.upload_draft_status(app.client, u.draft);
	if !ok || st != .Uploading return;
	frac := ifx total > 0 then cast(float32) sent / cast(float32) total else 0;
	track := ui.box("prog", .Draw_Background | .Floating_X | .Floating_Y);
	track.semantic_size = .[ui.px(CARD - 2 * CARD_PAD), ui.px(4)];
	track.fixed_pos = .{0, CARD_IMG_H - 4};
	track.style.bg = with_alpha(T("--background-mod-strong"), 0.8);
	{ ui.parent(track); defer ui.pop_parent();
		fill := ui.box("fill", .Draw_Background);
		fill.semantic_size = .[ui.px(max(0.08, frac) * (CARD - 2 * CARD_PAD)), ui.px(4)];
		fill.style.bg = T("--background-brand");
	}
	request_wake(app.ui.time + 0.1); // the upload's progress arrives without an event
}

modify_save :: (u: *Staged) {
	name := clean_filename(ui.editor_text(*att.mod_name), u.filename);
	desc := trim(ui.editor_text(*att.mod_desc), SPACES);
	spoiler_changed := att.mod_spoiler != u.spoiler;
	name = copy_string(name);
	free(u.filename);
	u.filename = name;
	free(u.description);
	u.description = copy_string(desc);
	u.spoiler = att.mod_spoiler;
	if app.client {
		dc.analytics_media_draft_edited(app.client, "has_alt_text", desc != "");
		if spoiler_changed dc.analytics_media_draft_edited(app.client, "spoilered", u.spoiler);
	}
	att.mod_key = 0;
}

// The client's upload modal look: dimmed window, a colored rounded card with a dashed-looking
// inner border, a file icon over its top edge, a title and a line. Returns true when clicked.
upload_card_overlay :: (id: string, title: string, lines: string, color: ui.Color, icon_name: string, clickable: bool) -> bool {
	flags: ui.Box_Flags = .Draw_Background | .Floating_X | .Floating_Y | .Overlay;
	if clickable flags |= .Clickable;
	scrim := ui.box(id, flags);
	scrim.semantic_size = .[ui.px(app.ui.window.x), ui.px(app.ui.window.y)];
	scrim.style.bg = .{0, 0, 0, 0.85};
	clicked := clickable && ui.signal(scrim).clicked;
	W :: 310;
	H :: 170;
	{ ui.parent(scrim); defer ui.pop_parent();
		c := ui.box("card", .Draw_Background | .Floating_X | .Floating_Y);
		c.semantic_size = .[ui.px(W), ui.px(H)];
		c.fixed_pos = .{(app.ui.window.x - W) / 2, (app.ui.window.y - H) / 2};
		c.style.bg = color;
		c.style.radius = all4(10);
		{ ui.parent(c); defer ui.pop_parent();
			inner := ui.box("inner", .Draw_Border | .Floating_X | .Floating_Y);
			inner.semantic_size = .[ui.px(W - 16), ui.px(H - 16)];
			inner.fixed_pos = .{8, 8};
			inner.style.border = 2;
			inner.style.border_color = .{1, 1, 1, 0.45};
			inner.style.radius = all4(6);
			inner.layout_axis = .Y;
			inner.cross_align = .Center;
			{ ui.parent(inner); defer ui.pop_parent();
				spacer(.Y, 56);
				label(title, .Bold, 20, .{1, 1, 1, 1}, 24);
				spacer(.Y, 8);
				for split(lines, "\n",, temp) label(tprint("%##sub%", it, it_index), .Normal, 14, .{1, 1, 1, 0.9}, 18);
			}
			// three tilted-looking file icons over the top edge
			for k: 0..2 {
				sz: float32 = ifx k == 1 then 72.0 else 56.0;
				ic := ui.box(tprint("ic%", k), .Draw_Background | .Floating_X | .Floating_Y);
				ic.semantic_size = .[ui.px(sz), ui.px(sz)];
				ic.fixed_pos = .{W / 2 - sz / 2 + cast(float32) (k - 1) * 56, ifx k == 1 then -36.0 else -22.0};
				ic.style.bg = .{1, 1, 1, 1};
				ic.style.radius = all4(10);
				{ ui.parent(ic); defer ui.pop_parent();
					i := ui.box("i", .Floating_X | .Floating_Y);
					i.semantic_size = .[ui.px(sz * 0.6), ui.px(sz * 0.6)];
					i.fixed_pos = .{sz * 0.2, sz * 0.2};
					set_icon(i, ifx k == 1 then icon_name else (ifx k == 0 then "image-file" else "paper"), color);
				}
			}
		}
	}
	return clicked;
}

rect_has :: (r: ui.Rect, p: ui.Vec2) -> bool { return p.x >= r.x0 && p.x < r.x1 && p.y >= r.y0 && p.y < r.y1; }
