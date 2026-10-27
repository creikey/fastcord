package app

// Staged attachments in the composer, like the official client:
//   - files come from the "+" picker, drag and drop (with the "Upload to #channel" overlay)
//     and Cmd/Ctrl+V (file URLs copied in Finder / Explorer, or a bitmap staged as image.png);
//   - each file is read, measured and thumbnailed on a worker thread, then starts uploading at
//     once (dc.upload_draft: the client uploads on staging, traffic/upload_options.jsonl);
//   - cards above the text area: thumbnail (image / video poster / file icon), filename, and
//     an action bar: Spoiler (eye), Modify (pencil: filename, alt text, spoiler), Remove (trash);
//   - limits: 10 files, and the upload size of the user's plan / the server's boost level,
//     shown as the client's "too powerful" / "too many uploads" notices.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import dc "fc:discord"
import "fc:gfx"
import "fc:imagefmt"
import "fc:locks"
import "fc:media"
import "fc:platform"
import "fc:ui"

MAX_ATTACHMENTS :: 10
MB :: 1024 * 1024

Att_Kind :: enum u8 {
	Other,
	Image,
	Video,
}

Staged :: struct {
	key:         u64, // stable UI id
	loading:     bool, // the worker is still reading / decoding it
	path:        string, // source file ("" for a pasted bitmap)
	filename:    string, // display name (renamed in Modify)
	description: string, // alt text
	spoiler:     bool,
	mime:        string,
	size:        i64,
	kind:        Att_Kind,
	origin:      string, // science origin of the upload
	draft:       u64, // dc.upload_draft handle (0 offline)
	thumb:       gfx.Texture,
	blur:        gfx.Texture, // a tiny copy, drawn stretched: the spoiler blur
	thumb_size:  [2]int,
	data:        []byte, // videos keep their bytes for the poster player
	player:      ^media.Player,
	poster:      media.Video_Image,
}

Att_Notice :: enum u8 {
	None,
	Too_Large,
	Too_Many,
}

Att_State :: struct {
	by_channel: map[dc.Snowflake][dynamic]Staged, // the client keeps a draft per channel
	next_key:   u64,
	// worker results
	mu:         locks.Mutex,
	results:    [dynamic]Att_Result,
	busy:       int, // jobs in flight (atomic)
	// overlays
	notice:     Att_Notice,
	drag:       bool, // files dragged over the window
	// Modify modal
	mod_channel: dc.Snowflake,
	mod_key:     u64, // 0 = closed
	mod_name:    ui.Editor,
	mod_desc:    ui.Editor,
	mod_spoiler: bool,
	mod_focus:   int, // 0 filename, 1 description
	// sent messages still uploading: nonce -> what they carry
	sending:    map[dc.Snowflake]Att_Sending,
	limit_override: i64, // UI scripts: a small limit to show the too-large notice
}

Att_Sending :: struct {
	channel: dc.Snowflake,
	drafts:  []u64,
	names:   []string,
	total:   i64,
}

att: Att_State

// ---- pure helpers (unit tested) ----

// Upload size limit in bytes: the user's plan (none 10 MB, Basic / Classic 50 MB, Nitro 500 MB)
// or the server's boost level (tier 2: 50 MB, tier 3: 100 MB), whichever is larger.
upload_limit :: proc(premium_type, guild_tier: int) -> i64 {
	user: i64 = 10 * MB
	switch premium_type {
	case 1, 3:
		user = 50 * MB
	case 2:
		user = 500 * MB
	}
	guild: i64 = 10 * MB
	if guild_tier == 2 do guild = 50 * MB
	if guild_tier >= 3 do guild = 100 * MB
	return max(user, guild)
}

channel_upload_limit :: proc(channel_id: dc.Snowflake) -> i64 {
	if att.limit_override > 0 do return att.limit_override
	s := store()
	premium, tier := 0, 0
	if u := dc.user_get(s, s.me); u != nil do premium = u.premium_type
	if ch := dc.channel_get(s, channel_id); ch != nil && ch.guild_id != 0 {
		if g, ok := &s.guilds[ch.guild_id]; ok do tier = g.premium_tier
	}
	return upload_limit(premium, tier)
}

// "Max file size is 10 MB please."
limit_text :: proc(limit: i64) -> string {
	if limit % MB == 0 do return fmt.tprintf("Max file size is %d MB please.", limit / MB)
	return fmt.tprintf("Max file size is %.2f MB please.", f64(limit) / MB)
}

// Would adding n files go over the cap? (the client rejects the whole batch)
too_many_files :: proc(have, adding: int) -> bool {return have + adding > MAX_ATTACHMENTS}

att_kind_of :: proc(mime: string) -> Att_Kind {
	if strings.has_prefix(mime, "image/") do return .Image
	if strings.has_prefix(mime, "video/") do return .Video
	return .Other
}

// File-type icon for a card without a thumbnail.
file_icon_for :: proc(name: string) -> string {
	ext := strings.to_lower(filepath.ext(name), context.temp_allocator)
	switch ext {
	case ".mp4", ".mov", ".webm", ".mkv", ".avi":
		return "video"
	case ".mp3", ".ogg", ".wav", ".flac", ".m4a", ".opus":
		return "music"
	case ".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".heic":
		return "image-file"
	case ".txt", ".md", ".pdf", ".doc", ".docx", ".rtf":
		return "paper"
	case ".odin", ".c", ".h", ".py", ".js", ".ts", ".go", ".rs", ".json", ".html", ".css", ".sh":
		return "angle-brackets"
	}
	return "file"
}

// A filename the user typed in Modify: no path separators, never empty.
clean_filename :: proc(name, fallback: string) -> string {
	n := strings.trim_space(name)
	n, _ = strings.replace_all(n, "/", "_", context.temp_allocator)
	n, _ = strings.replace_all(n, "\\", "_", context.temp_allocator)
	return n != "" ? n : fallback
}

// Box-filter downscale to fit max_side (no upscale). Returns RGBA.
downscale :: proc(px: []byte, w, h, max_side: int, allocator := context.allocator) -> (out: []byte, ow, oh: int) {
	sc := min(1, f64(max_side) / f64(max(w, h)))
	ow = max(1, int(f64(w) * sc + 0.5))
	oh = max(1, int(f64(h) * sc + 0.5))
	out = make([]byte, ow * oh * 4, allocator)
	for y in 0 ..< oh {
		y0 := y * h / oh
		y1 := max(y0 + 1, (y + 1) * h / oh)
		for x in 0 ..< ow {
			x0 := x * w / ow
			x1 := max(x0 + 1, (x + 1) * w / ow)
			// at most 4x4 samples per output pixel
			sy := max(1, (y1 - y0) / 4)
			sx := max(1, (x1 - x0) / 4)
			acc: [4]int
			n := 0
			for yy := y0; yy < y1; yy += sy {
				for xx := x0; xx < x1; xx += sx {
					p := px[(yy * w + xx) * 4:]
					acc += {int(p[0]), int(p[1]), int(p[2]), int(p[3])}
					n += 1
				}
			}
			o := out[(y * ow + x) * 4:]
			for c in 0 ..< 4 do o[c] = u8(acc[c] / n)
		}
	}
	return
}

// ---- worker ----

Att_Job_Kind :: enum u8 {
	File,
	Paste_Image,
	Paste_Files,
}

Att_Error :: enum u8 {
	None,
	Read_Failed,
	Too_Large,
	Empty,
}

Att_Result :: struct {
	kind:    Att_Job_Kind,
	key:     u64,
	channel: dc.Snowflake,
	err:     Att_Error,
	data:    []byte,
	size:    i64,
	thumb:   []byte,
	tw, th:  int,
	blur:    []byte,
	bw, bh:  int,
	paths:   []string, // Paste_Files: the clipboard's files
}

@(private = "file")
Att_Job :: struct {
	kind:    Att_Job_Kind,
	key:     u64,
	channel: dc.Snowflake,
	path:    string,
	mime:    string,
	limit:   i64,
}

@(private = "file")
att_spawn :: proc(j: Att_Job) {
	job := new(Att_Job)
	job^ = j
	job.path = strings.clone(j.path)
	job.mime = strings.clone(j.mime)
	sync.atomic_add(&att.busy, 1)
	thread.create_and_start_with_poly_data(job, att_work, self_cleanup = true)
}

@(private = "file")
att_work :: proc(j: ^Att_Job) {
	res := Att_Result{kind = j.kind, key = j.key, channel = j.channel}
	switch j.kind {
	case .Paste_Files:
		res.paths = platform.clipboard_files()
	case .Paste_Image:
		img, ok := platform.clipboard_image()
		if !ok {
			res.err = .Empty
		} else if len(img.png) > 0 {
			res.data = img.png
		} else {
			res.data = imagefmt.encode_png(img.rgba, img.width, img.height)
			delete(img.rgba)
		}
	case .File:
		size: i64 = -1
		if fi, err := os.stat(j.path, context.temp_allocator); err == nil do size = fi.size
		if size < 0 {
			res.err = .Read_Failed
		} else if size > j.limit {
			res.err = .Too_Large
			res.size = size
		} else {
			data, err := os.read_entire_file(j.path, context.allocator)
			if err != nil do res.err = .Read_Failed
			else do res.data = data
		}
	}
	if j.kind != .Paste_Files && res.err == .None {
		res.size = i64(len(res.data))
		if res.size > j.limit {
			res.err = .Too_Large
			delete(res.data)
			res.data = nil
		} else if strings.has_prefix(j.mime, "image/") || j.kind == .Paste_Image {
			// thumbnail off the UI thread: 400 px (the 184x156 card area at 2x), plus a
			// 12 px copy drawn stretched as the spoiler blur
			if img, err := imagefmt.decode_first_frame(res.data, context.temp_allocator, 64 << 20); err == nil && len(img.frames) > 0 {
				res.thumb, res.tw, res.th = downscale(img.frames[0].pixels, img.width, img.height, 400)
				res.blur, res.bw, res.bh = downscale(res.thumb, res.tw, res.th, 12)
			}
		}
	}
	locks.lock(&att.mu)
	append(&att.results, res)
	locks.unlock(&att.mu)
	sync.atomic_sub(&att.busy, 1)
	delete(j.path)
	delete(j.mime)
	free(j)
	free_all(context.temp_allocator)
	platform.request_frame()
}

// Jobs still running (tests wait for them).
attachments_busy :: proc() -> bool {
	if sync.atomic_load(&att.busy) > 0 do return true
	locks.lock(&att.mu)
	defer locks.unlock(&att.mu)
	return len(att.results) > 0
}

// ---- staging ----

staged_list :: proc(channel_id: dc.Snowflake) -> ^[dynamic]Staged {
	if l, ok := &att.by_channel[channel_id]; ok do return l
	att.by_channel[channel_id] = make([dynamic]Staged)
	return &att.by_channel[channel_id]
}

staged_count :: proc(channel_id: dc.Snowflake) -> int {
	if l, ok := att.by_channel[channel_id]; ok do return len(l)
	return 0
}

// Files from the picker, a drop or a paste: one loading card each, read on a worker.
stage_paths :: proc(channel_id: dc.Snowflake, paths: []string, origin: string) {
	if channel_id == 0 || len(paths) == 0 do return
	l := staged_list(channel_id)
	if too_many_files(len(l), len(paths)) {
		att.notice = .Too_Many
		return
	}
	limit := channel_upload_limit(channel_id)
	for p in paths {
		att.next_key += 1
		name := filepath.base(p)
		mime := mime_for(name)
		append(l, Staged{key = att.next_key, loading = true, path = strings.clone(p), filename = strings.clone(name), mime = strings.clone(mime), kind = att_kind_of(mime), origin = origin})
		att_spawn({kind = .File, key = att.next_key, channel = channel_id, path = p, mime = mime, limit = limit})
	}
}

// Cmd/Ctrl+V in the composer: files or a bitmap on the clipboard are staged (true: handled);
// otherwise the text field pastes text.
paste_attachments :: proc(channel_id: dc.Snowflake) -> bool {
	switch platform.clipboard_kind() {
	case .Files:
		att_spawn({kind = .Paste_Files, channel = channel_id})
		return true
	case .Image:
		if too_many_files(staged_count(channel_id), 1) {
			att.notice = .Too_Many
			return true
		}
		att_spawn({kind = .Paste_Image, channel = channel_id, mime = "image/png", limit = channel_upload_limit(channel_id)})
		return true
	case .Text, .None:
	}
	return false
}

@(private = "file")
staged_free :: proc(u: ^Staged) {
	if u.player != nil do media.player_destroy(u.player)
	if u.thumb != 0 do gfx.texture_destroy(u.thumb)
	if u.blur != 0 do gfx.texture_destroy(u.blur)
	delete(u.path)
	delete(u.filename)
	delete(u.description)
	delete(u.mime)
	delete(u.data)
}

// Remove (trash): the uploaded file is deleted from the bucket too.
staged_remove :: proc(channel_id: dc.Snowflake, key: u64) {
	l := staged_list(channel_id)
	for &u, i in l {
		if u.key != key do continue
		if u.draft != 0 && app.client != nil do dc.upload_draft_remove(app.client, u.draft)
		staged_free(&u)
		ordered_remove(l, i)
		return
	}
}

staged_find :: proc(channel_id: dc.Snowflake, key: u64) -> ^Staged {
	l, ok := &att.by_channel[channel_id]
	if !ok do return nil
	for &u in l do if u.key == key do return &u
	return nil
}

// Per frame: worker results become cards (and uploads), video posters load.
attachments_frame :: proc() {
	locks.lock(&att.mu)
	results := slice.clone(att.results[:], context.temp_allocator)
	clear(&att.results)
	locks.unlock(&att.mu)
	for &r in results {
		defer {
			delete(r.thumb)
			delete(r.blur)
			for p in r.paths do delete(p)
			delete(r.paths)
		}
		switch r.kind {
		case .Paste_Files:
			if len(r.paths) > 0 do stage_paths(r.channel, r.paths, "clipboard")
			continue
		case .Paste_Image:
			if r.err == .Too_Large {
				att.notice = .Too_Large
				continue
			}
			if r.err != .None do continue
			l := staged_list(r.channel)
			if too_many_files(len(l), 1) {
				att.notice = .Too_Many
				delete(r.data)
				continue
			}
			att.next_key += 1
			// the name Chromium gives a pasted bitmap
			append(l, Staged{key = att.next_key, loading = true, filename = strings.clone("image.png"), mime = strings.clone("image/png"), kind = .Image, origin = "clipboard"})
			r.key = att.next_key
		case .File:
		}
		u := staged_find(r.channel, r.key)
		if u == nil {
			delete(r.data) // removed while loading
			continue
		}
		if r.err != .None {
			if r.err == .Too_Large do att.notice = .Too_Large
			staged_remove(r.channel, r.key)
			delete(r.data)
			continue
		}
		u.loading = false
		u.size = r.size
		if len(r.thumb) > 0 {
			u.thumb = gfx.texture_from_rgba(r.tw, r.th, r.thumb)
			u.thumb_size = {r.tw, r.th}
			u.blur = gfx.texture_from_rgba(r.bw, r.bh, r.blur)
		}
		if app.client != nil do u.draft = dc.upload_draft(app.client, r.channel, u.filename, u.mime, r.data, u.origin)
		if u.kind == .Video {
			u.data = r.data // the poster player reads it in place
			ensure_audio()
			u.player = media.player_open(media.source_from_memory(u.data), autoplay = false, muted = true)
		} else {
			delete(r.data)
		}
		app.ui.animating = true
	}
	// video posters: the player decodes its first frame on its own thread
	for _, &l in att.by_channel {
		for &u in l {
			if u.player == nil || u.poster.y != 0 do continue
			img, _ := media.player_update(u.player)
			if img.y != 0 do u.poster = img
			else if media.player_state(u.player) != .Error do request_wake(app.ui.time + 0.05)
		}
	}
	// sent messages: forget the ones that landed
	for nonce, sn in att.sending {
		done := true
		for d in sn.drafts {
			if st, _, _, ok := dc.upload_draft_status(app.client, d); ok && st == .Uploading do done = false
		}
		if done {
			delete(sn.drafts)
			for n in sn.names do delete(n)
			delete(sn.names)
			delete_key(&att.sending, nonce)
		}
	}
}

// Send: the composer's staged files go with the message (they are already uploading).
// Returns false while a file is still being read.
attachments_for_send :: proc(channel_id: dc.Snowflake, allocator := context.temp_allocator) -> (out: []dc.Draft_Attachment, ready: bool) {
	l, ok := &att.by_channel[channel_id]
	if !ok || len(l) == 0 do return nil, true
	out = make([]dc.Draft_Attachment, len(l), allocator)
	for u, i in l {
		if u.loading do return nil, false
		out[i] = {handle = u.draft, filename = u.filename, description = u.description, spoiler = u.spoiler}
	}
	return out, true
}

// After send: remember what the pending message uploads (its progress bar), clear the cards
// without deleting the uploads (they now belong to the message).
attachments_sent :: proc(channel_id: dc.Snowflake, nonce: dc.Snowflake) {
	l, ok := &att.by_channel[channel_id]
	if !ok do return
	if nonce != 0 && len(l) > 0 {
		sn := Att_Sending{channel = channel_id, drafts = make([]u64, len(l)), names = make([]string, len(l))}
		for u, i in l {
			sn.drafts[i] = u.draft
			sn.names[i] = strings.clone(u.filename)
			sn.total += u.size
		}
		att.sending[nonce] = sn
	}
	for &u in l do staged_free(&u)
	clear(l)
}

attachments_modal_open :: proc() -> bool {return att.mod_key != 0 || att.notice != .None}

// ---- cards ----

CARD :: 200
CARD_PAD :: 8
CARD_IMG_H :: 156
BAR_BTN :: 32

@(private = "file")
Thumb_Draw :: struct {
	tex:     gfx.Texture,
	size:    [2]int,
	video:   media.Video_Image,
	blurred: bool,
}

// Draws the thumbnail "contain"-fitted (images, video posters); the spoiler draws the tiny copy stretched.
@(private = "file")
thumb_draw :: proc(b: ^ui.Box, user: rawptr) {
	d := (^Thumb_Draw)(user)
	r := gfx.Rect(b.rect)
	bw, bh := r.x1 - r.x0, r.y1 - r.y0
	size := d.size
	if d.video.y != 0 do size = d.video.size
	if size.x <= 0 || size.y <= 0 do return
	if d.blurred {
		// cover the whole area, blurry
		white := gfx.Color{1, 1, 1, b.opacity}
		gfx.push_rect({dst = r, tex = d.tex, colors = {white, white, white, white}, radii = b.style.radius})
		return
	}
	sc := min(bw / f32(size.x), bh / f32(size.y))
	w, h := f32(size.x) * sc, f32(size.y) * sc
	x0, y0 := r.x0 + (bw - w) / 2, r.y0 + (bh - h) / 2
	dst := gfx.Rect{x0, y0, x0 + w, y0 + h}
	if d.video.y != 0 {
		gfx.video(dst, d.video.y, d.video.cbcr, d.video.yuv, 3)
		return
	}
	white := gfx.Color{1, 1, 1, b.opacity}
	gfx.push_rect({dst = dst, tex = d.tex, colors = {white, white, white, white}, radii = {3, 3, 3, 3}})
}

// The row of staged cards above the text area (horizontally scrollable).
uploads_bar :: proc(channel_id: dc.Snowflake) {
	l, ok := &att.by_channel[channel_id]
	if !ok || len(l) == 0 do return
	bar := row("uploads", {.Scroll_X, .Clip})
	bar.semantic_size = {.X = ui.pct(1), .Y = ui.px(20 + CARD + 10)}
	bar.cross_align = .Start
	// a vertical wheel scrolls the row sideways, like the client's overflow-x area
	for &e in app.ui.events {
		if e.kind == .Scroll && !e.consumed && e.delta.x == 0 && rect_has(ui.visible_rect(bar), app.ui.mouse) {
			bar.view_off_target.x -= e.delta.y
			e.consumed = true
		}
	}
	ui.signal(bar)
	remove: u64
	if ui.parent(bar) {
		spacer(.X, 10)
		for &u, i in l {
			if i > 0 do spacer(.X, 24)
			if staged_card(channel_id, &u) do remove = u.key
		}
		spacer(.X, 10)
	}
	if remove != 0 do staged_remove(channel_id, remove)
	sep := ui.box("upsep", {.Draw_Background})
	sep.semantic_size = {.X = ui.pct(1), .Y = ui.px(1)}
	sep.style.bg = T("--border-subtle")
}

// One card; true when Remove was clicked.
@(private = "file")
staged_card :: proc(channel_id: dc.Snowflake, u: ^Staged) -> (removed: bool) {
	col := ui.box(fmt.tprintf("upc%d", u.key))
	col.semantic_size = {.X = ui.px(CARD), .Y = ui.px(20 + CARD)}
	col.layout_axis = .Y
	ui.push_parent(col)
	defer ui.pop_parent()
	spacer(.Y, 20) // room for the action bar riding over the corner
	card := ui.box("card", {.Draw_Background})
	card.semantic_size = {.X = ui.px(CARD), .Y = ui.px(CARD)}
	card.style.bg = T("--background-base-low")
	card.style.radius = 4
	card.layout_axis = .Y
	if ui.parent(card) {
		spacer(.Y, CARD_PAD)
		r := row("imgrow")
		r.semantic_size = {.X = ui.pct(1), .Y = ui.px(CARD_IMG_H)}
		if ui.parent(r) {
			spacer(.X, CARD_PAD)
			area := ui.box("img", {.Clip})
			area.semantic_size = {.X = ui.px(CARD - 2 * CARD_PAD), .Y = ui.px(CARD_IMG_H)}
			area.style.radius = 3
			area.layout_axis = .Y
			area.cross_align = .Center
			has_thumb := u.thumb != 0 || u.poster.y != 0
			if has_thumb {
				d := new(Thumb_Draw, context.temp_allocator)
				d^ = {tex = u.thumb, size = u.thumb_size, video = u.poster}
				if u.spoiler {
					d.tex = u.blur
					d.video = {}
					d.blurred = true
				}
				area.custom_draw = thumb_draw
				area.custom_user = d
			}
			if ui.parent(area) {
				if !has_thumb || (u.spoiler && u.blur == 0) {
					spacer(.Y, (CARD_IMG_H - 64) / 2)
					icon("ficon", file_icon_for(u.filename), 64, T("--interactive-icon-default"))
				}
				if u.spoiler do spoiler_pill()
				if u.draft != 0 do upload_progress_line(u)
			}
		}
		spacer(.Y, CARD_PAD)
		nr := row("name")
		nr.semantic_size = {.X = ui.pct(1), .Y = ui.px(20)}
		if ui.parent(nr) {
			spacer(.X, CARD_PAD)
			label(fmt.tprintf("%s##fname", ellipsize(u.filename, .Normal, 14, CARD - 2 * CARD_PAD)), .Normal, 14, T("--text-default"), 20)
		}
	}
	// action bar over the top-right corner (translate(25%, -25%) in the client's CSS)
	W :: 3 * BAR_BTN + 2 * 4
	H :: BAR_BTN + 2 * 4
	ab := row("actions", {.Draw_Background, .Draw_Border, .Draw_Shadow, .Floating_X, .Floating_Y})
	ab.semantic_size = {.X = ui.px(W), .Y = ui.px(H)}
	ab.fixed_pos = {CARD - W * 0.75, 20 - H * 0.25 - 4}
	ab.style.bg = T("--background-surface-higher")
	ab.style.border_color = T("--border-subtle")
	ab.style.border = 1
	ab.style.radius = 8
	ab.style.shadow_color = {0, 0, 0, 0.16}
	ab.style.shadow_blur = 4
	ui.signal(ab)
	if ui.parent(ab) {
		spacer(.X, 4)
		Btn :: struct {
			id, icon, tip: string,
			danger:        bool,
		}
		btns := [3]Btn{
			{"spoiler", u.spoiler ? "eye-slash" : "eye", u.spoiler ? "Remove Spoiler" : "Spoiler Attachment", false},
			{"modify", "pencil", "Modify Attachment", false},
			{"remove", "trash", "Remove Attachment", true},
		}
		for bt in btns {
			b := ui.box(bt.id, {.Clickable, .Draw_Background, .Hot_Animation})
			b.semantic_size = {.X = ui.px(BAR_BTN), .Y = ui.px(BAR_BTN)}
			b.style.radius = 6
			b.style.bg_hot = T("--background-mod-subtle")
			b.layout_axis = .X
			b.cross_align = .Center
			sig := ui.signal(b)
			if ui.parent(b) {
				spacer(.X, 6)
				c := sig.hovering ? T("--interactive-icon-hover") : T("--interactive-icon-default")
				if bt.danger do c = T("--status-danger")
				icon("i", bt.icon, 20, c)
			}
			if sig.hovering do tooltip_below(bt.tip, b.rect)
			if sig.clicked {
				switch bt.id {
				case "spoiler":
					u.spoiler = !u.spoiler
					if app.client != nil do dc.analytics_media_draft_edited(app.client, "spoilered", u.spoiler)
				case "modify":
					modify_open(channel_id, u)
				case "remove":
					removed = true
				}
			}
		}
	}
	return
}

@(private = "file")
spoiler_pill :: proc() {
	W :: 74
	p := row("spoiler", {.Draw_Background, .Floating_X, .Floating_Y})
	p.semantic_size = {.X = ui.px(W), .Y = ui.px(24)}
	p.fixed_pos = {(CARD - 2 * CARD_PAD - W) / 2, (CARD_IMG_H - 24) / 2}
	p.style.bg = {0, 0, 0, 0.6}
	p.style.radius = 12
	if ui.parent(p) {
		spacer(.X, 12)
		label("SPOILER", .Bold, 12, {1, 1, 1, 1}, 16)
	}
}

// Thin bar along the bottom of the thumbnail while the staged file uploads.
@(private = "file")
upload_progress_line :: proc(u: ^Staged) {
	st, sent, total, ok := dc.upload_draft_status(app.client, u.draft)
	if !ok || st != .Uploading do return
	frac := total > 0 ? f32(sent) / f32(total) : 0
	track := ui.box("prog", {.Draw_Background, .Floating_X, .Floating_Y})
	track.semantic_size = {.X = ui.px(CARD - 2 * CARD_PAD), .Y = ui.px(4)}
	track.fixed_pos = {0, CARD_IMG_H - 4}
	track.style.bg = with_alpha(T("--background-mod-strong"), 0.8)
	if ui.parent(track) {
		fill := ui.box("fill", {.Draw_Background})
		fill.semantic_size = {.X = ui.px(max(0.08, frac) * (CARD - 2 * CARD_PAD)), .Y = ui.px(4)}
		fill.style.bg = T("--background-brand")
	}
	request_wake(app.ui.time + 0.1) // the upload's progress arrives without an event
}

// A sent message whose files are still uploading: the client shows it pending with a progress bar.
upload_progress_view :: proc(m: ^dc.Message) {
	sn, ok := att.sending[m.id]
	if !ok || app.client == nil do return
	sent: i64
	for d in sn.drafts {
		if _, s, _, ok2 := dc.upload_draft_status(app.client, d); ok2 do sent += s
	}
	f := row("uploading", {.Draw_Background, .Draw_Border})
	f.semantic_size = {.X = ui.px(432), .Y = ui.px(72)}
	f.style.bg = T("--background-surface-high")
	f.style.border_color = T("--border-subtle")
	f.style.border = 1
	f.style.radius = 8
	if ui.parent(f) {
		spacer(.X, 16)
		icon("ficon", file_icon_for(sn.names[0]), 30, T("--interactive-icon-default"))
		spacer(.X, 8)
		col := ui.box("col")
		col.semantic_size = {.X = ui.fill(), .Y = ui.children()}
		col.layout_axis = .Y
		if ui.parent(col) {
			name := len(sn.names) == 1 ? sn.names[0] : fmt.tprintf("%d files", len(sn.names))
			label(fmt.tprintf("%s##upname", name), .Normal, 16, T("--text-default"), 20)
			spacer(.Y, 6)
			track := ui.box("track", {.Draw_Background})
			track.semantic_size = {.X = ui.pct(1), .Y = ui.px(6)}
			track.style.bg = T("--background-mod-strong")
			track.style.radius = 3
			if ui.parent(track) {
				frac := sn.total > 0 ? f32(sent) / f32(sn.total) : 0
				fill := ui.box("fill", {.Draw_Background})
				fill.semantic_size = {.X = ui.pct(max(0.05, frac)), .Y = ui.px(6)}
				fill.style.bg = T("--background-brand")
				fill.style.radius = 3
			}
		}
		spacer(.X, 16)
	}
	spacer(.Y, 4)
	request_wake(app.ui.time + 0.1)
}

// ---- Modify modal ----

modify_open :: proc(channel_id: dc.Snowflake, u: ^Staged) {
	att.mod_channel = channel_id
	att.mod_key = u.key
	att.mod_spoiler = u.spoiler
	att.mod_focus = 0
	ui.editor_set_text(&att.mod_name, u.filename)
	ui.editor_set_text(&att.mod_desc, u.description)
}

@(private = "file")
modify_save :: proc(u: ^Staged) {
	name := clean_filename(ui.editor_text(&att.mod_name), u.filename)
	desc := strings.trim_space(ui.editor_text(&att.mod_desc))
	spoiler_changed := att.mod_spoiler != u.spoiler
	name = strings.clone(name)
	delete(u.filename)
	u.filename = name
	delete(u.description)
	u.description = strings.clone(desc)
	u.spoiler = att.mod_spoiler
	if app.client != nil {
		dc.analytics_media_draft_edited(app.client, "has_alt_text", desc != "")
		if spoiler_changed do dc.analytics_media_draft_edited(app.client, "spoilered", u.spoiler)
	}
	att.mod_key = 0
}

modify_modal :: proc() {
	u := staged_find(att.mod_channel, att.mod_key)
	if u == nil {
		att.mod_key = 0
		return
	}
	scrim := ui.box("mod_scrim", {.Draw_Background, .Clickable, .Floating_X, .Floating_Y, .Overlay})
	scrim.semantic_size = {.X = ui.px(app.ui.window.x), .Y = ui.px(app.ui.window.y)}
	scrim.style.bg = {0, 0, 0, 0.7}
	if ui.signal(scrim).clicked {
		att.mod_key = 0
		return
	}
	W :: 440
	PAD :: 24
	d := ui.box("modmodal", {.Draw_Background, .Draw_Border, .Floating_X, .Floating_Y, .Overlay, .Clickable})
	d.semantic_size = {.X = ui.px(W), .Y = ui.children()}
	d.fixed_pos = {(app.ui.window.x - W) / 2, (app.ui.window.y - (d.rect.y1 - d.rect.y0)) / 2}
	d.style.bg = T("--modal-background")
	d.style.border_color = T("--border-subtle")
	d.style.border = 1
	d.style.radius = 12
	d.layout_axis = .Y
	ui.signal(d)
	ui.push_parent(d)
	defer ui.pop_parent()
	text_row :: proc(id, text: string, font: Font_Id, size, lh: f32, color: ui.Color) {
		r := row(id)
		r.semantic_size = {.X = ui.pct(1), .Y = ui.px(lh)}
		if ui.parent(r) {
			spacer(.X, PAD)
			label(text, font, size, color, lh)
		}
	}
	save, cancel := false, false
	field :: proc(id: string, ed: ^ui.Editor, placeholder: string, idx: int) -> ui.Edit_Result {
		res := ui.Edit_Result.None
		ir := row(id)
		ir.semantic_size = {.X = ui.pct(1), .Y = ui.px(40)}
		if ui.parent(ir) {
			spacer(.X, PAD)
			box := row("input", {.Draw_Background, .Draw_Border, .Clickable})
			box.semantic_size = {.X = ui.fill(), .Y = ui.px(40)}
			box.style.bg = T("--input-background-default")
			box.style.border_color = att.mod_focus == idx ? T("--input-border-active") : T("--input-border-default")
			box.style.border = 1
			box.style.radius = 8
			box.hover_cursor = .IBeam
			if ui.signal(box).pressed do att.mod_focus = idx
			if ui.parent(box) {
				spacer(.X, 12)
				before := app.ui.focus
				res = text_field("field", ed, placeholder, att.mod_focus == idx, 16, 20, 10, T("--input-placeholder-text-default"))
				// a press on the text itself focuses the container (text_field)
				if app.ui.focus != before && app.ui.focus == box.key do att.mod_focus = idx
				spacer(.X, 12)
			}
			spacer(.X, PAD)
		}
		return res
	}
	spacer(.Y, PAD)
	text_row("t", fmt.tprintf("%s##modtitle", ellipsize(u.filename, .Semibold, 20, W - 2 * PAD)), .Semibold, 20, 24, T("--text-strong"))
	spacer(.Y, 20)
	text_row("lname", "Filename", .Medium, 14, 18, T("--text-strong"))
	spacer(.Y, 8)
	r1 := field("namerow", &att.mod_name, "", 0)
	spacer(.Y, 16)
	text_row("ldesc", "Description (alt text)", .Medium, 14, 18, T("--text-strong"))
	spacer(.Y, 8)
	r2 := field("descrow", &att.mod_desc, "Add a description", 1)
	for r in ([]ui.Edit_Result{r1, r2}) {
		if r == .Submit do save = true
		if r == .Escape do cancel = true
	}
	spacer(.Y, 16)
	cr := row("spoilerrow", {.Clickable})
	cr.semantic_size = {.X = ui.pct(1), .Y = ui.px(24)}
	if ui.signal(cr).clicked do att.mod_spoiler = !att.mod_spoiler
	if ui.parent(cr) {
		spacer(.X, PAD)
		cb := ui.box("check", {.Draw_Background, .Draw_Border})
		cb.semantic_size = {.X = ui.px(20), .Y = ui.px(20)}
		cb.style.radius = 6
		cb.style.border = att.mod_spoiler ? 0 : 1
		cb.style.border_color = T("--checkbox-border-default")
		cb.style.bg = att.mod_spoiler ? T("--background-brand") : {}
		if att.mod_spoiler {
			if ui.parent(cb) {
				i := ui.box("i", {.Floating_X, .Floating_Y})
				i.semantic_size = {.X = ui.px(18), .Y = ui.px(18)}
				i.fixed_pos = {1, 1}
				set_icon(i, "checkmark-small", {1, 1, 1, 1})
			}
		}
		spacer(.X, 8)
		label("Mark as spoiler", .Normal, 16, T("--text-default"), 20)
	}
	spacer(.Y, PAD)
	btns := row("btns", {.Draw_Background})
	btns.semantic_size = {.X = ui.pct(1), .Y = ui.px(70)}
	btns.style.bg = T("--background-base-lower")
	btns.style.radius = {0, 0, 12, 12}
	btns.style.child_gap = 8
	button :: proc(id: string, w: f32, bg, bg_hot, fg: ui.Color) -> bool {
		b := ui.box(id, {.Clickable, .Draw_Background, .Draw_Text, .Hot_Animation})
		b.semantic_size = {.X = ui.px(w), .Y = ui.px(38)}
		b.style.radius = 8
		b.style.font = F(.Medium)
		b.style.font_size = 14
		b.style.text_align = .Center
		b.style.text_color = fg
		b.style.bg = bg
		b.style.bg_hot = bg_hot
		return ui.signal(b).clicked
	}
	if ui.parent(btns) {
		filler(.X)
		if button("Cancel##modcancel", 96, T("--background-mod-normal"), T("--background-mod-strong"), T("--text-strong")) do cancel = true
		if button("Save##modsave", 96, T("--background-brand"), with_alpha(T("--background-brand"), 0.85), {1, 1, 1, 1}) do save = true
		spacer(.X, PAD - 8)
	}
	for &e in app.ui.events {
		if e.consumed || e.kind != .Key_Down do continue
		if e.key == .Escape {
			e.consumed = true
			cancel = true
		} else if e.key == .Tab {
			e.consumed = true
			att.mod_focus = 1 - att.mod_focus
		}
	}
	if save do modify_save(u)
	else if cancel do att.mod_key = 0
	if att.mod_key == 0 do app.ui.focus = 0 // back to the composer, like the client
}

// ---- overlays: drag target, limit notices ----

attachments_overlays :: proc() {
	if att.mod_key != 0 do modify_modal()
	ch := dc.channel_get(store(), app.view.channel)
	if att.notice != .None {
		title, sub: string
		switch att.notice {
		case .Too_Large:
			title = "Your files are too powerful"
			sub = limit_text(channel_upload_limit(app.view.channel))
		case .Too_Many:
			title = "Too many uploads!"
			sub = fmt.tprintf("You can only upload %d files at a time!", MAX_ATTACHMENTS)
		case .None:
		}
		if upload_card_overlay("att_notice", title, sub, T("--status-danger"), "file-warning", true) do att.notice = .None
		for &e in app.ui.events {
			if !e.consumed && e.kind == .Key_Down && e.key == .Escape {
				e.consumed = true
				att.notice = .None
			}
		}
	} else if att.drag && ch != nil {
		where_ := ch.kind == .DM ? fmt.tprintf("@%s", dm_name(ch)) : (ch.kind == .Group_DM ? dm_name(ch) : fmt.tprintf("#%s", ch.name))
		upload_card_overlay("att_drag", fmt.tprintf("Upload to %s", where_), "You can add comments before uploading.\nHold shift to upload directly.", T("--background-brand"), "file-up", false)
	}
}

// The client's upload modal look: dimmed window, a colored rounded card with a dashed-looking
// inner border, a file icon over its top edge, a title and a line. Returns true when clicked.
@(private = "file")
upload_card_overlay :: proc(id, title, sub: string, color: ui.Color, icon_name: string, clickable: bool) -> bool {
	flags: ui.Box_Flags = {.Draw_Background, .Floating_X, .Floating_Y, .Overlay}
	if clickable do flags += {.Clickable}
	scrim := ui.box(id, flags)
	scrim.semantic_size = {.X = ui.px(app.ui.window.x), .Y = ui.px(app.ui.window.y)}
	scrim.style.bg = {0, 0, 0, 0.85}
	clicked := clickable && ui.signal(scrim).clicked
	W :: 310
	H :: 170
	if ui.parent(scrim) {
		c := ui.box("card", {.Draw_Background, .Floating_X, .Floating_Y})
		c.semantic_size = {.X = ui.px(W), .Y = ui.px(H)}
		c.fixed_pos = {(app.ui.window.x - W) / 2, (app.ui.window.y - H) / 2}
		c.style.bg = color
		c.style.radius = 10
		if ui.parent(c) {
			inner := ui.box("inner", {.Draw_Border, .Floating_X, .Floating_Y})
			inner.semantic_size = {.X = ui.px(W - 16), .Y = ui.px(H - 16)}
			inner.fixed_pos = {8, 8}
			inner.style.border = 2
			inner.style.border_color = {1, 1, 1, 0.45}
			inner.style.radius = 6
			inner.layout_axis = .Y
			inner.cross_align = .Center
			if ui.parent(inner) {
				spacer(.Y, 56)
				label(title, .Bold, 20, {1, 1, 1, 1}, 24)
				spacer(.Y, 8)
				for line, i in strings.split(sub, "\n", context.temp_allocator) {
					label(fmt.tprintf("%s##sub%d", line, i), .Normal, 14, {1, 1, 1, 0.9}, 18)
				}
			}
			// three tilted-looking file icons over the top edge
			for k in 0 ..< 3 {
				sz: f32 = k == 1 ? 72 : 56
				ic := ui.box(fmt.tprintf("ic%d", k), {.Draw_Background, .Floating_X, .Floating_Y})
				ic.semantic_size = {.X = ui.px(sz), .Y = ui.px(sz)}
				ic.fixed_pos = {W / 2 - sz / 2 + f32(k - 1) * 56, k == 1 ? -36 : -22}
				ic.style.bg = {1, 1, 1, 1}
				ic.style.radius = 10
				if ui.parent(ic) {
					i := ui.box("i", {.Floating_X, .Floating_Y})
					i.semantic_size = {.X = ui.px(sz * 0.6), .Y = ui.px(sz * 0.6)}
					i.fixed_pos = {sz * 0.2, sz * 0.2}
					set_icon(i, k == 1 ? icon_name : (k == 0 ? "image-file" : "paper"), color)
				}
			}
		}
	}
	return clicked
}

// Platform drag events (main loop).
attachments_drag_event :: proc(e: platform.Event) {
	#partial switch e.kind {
	case .Drag_Enter:
		att.drag = true
	case .Drag_Leave:
		att.drag = false
	}
}

@(private = "file")
rect_has :: proc(r: ui.Rect, p: ui.Vec2) -> bool {return p.x >= r.x0 && p.x < r.x1 && p.y >= r.y0 && p.y < r.y1}

// Sweep: back to no staged files (waits for in-flight reads first).
attachments_reset_for_test :: proc() {
	for attachments_busy() {
		attachments_frame()
		thread.yield()
	}
	for _, &l in att.by_channel {
		for &u in l do staged_free(&u)
		delete(l)
	}
	delete(att.by_channel)
	for _, sn in att.sending {
		delete(sn.drafts)
		for n in sn.names do delete(n)
		delete(sn.names)
	}
	delete(att.sending)
	delete(att.results)
	ui.editor_set_text(&att.mod_name, "")
	ui.editor_set_text(&att.mod_desc, "")
	name, desc := att.mod_name, att.mod_desc
	att = {}
	att.mod_name, att.mod_desc = name, desc
}
