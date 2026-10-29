// Inline players for video/audio attachments, embeds, and the image viewer.

Blob :: struct {
	state: Image_State;
	retry: Retry;
	data: []u8;
	stream: *media.Growing_Buffer; // blob_stream's: the bytes so far (data stays empty)
}

// Raw downloads (videos, audio, text) keyed by URL; they share the media fetch path with images.
blobs: Table(string, Blob);

Inline_Player :: struct {
	player: *media.Player;
	url: string;
	poster: string;
	voice: bool; // a voice message: plays at voice_rate
	size: Vector2; // inline size: the fullscreen view's aspect
	img: media.Video_Image;
}

players: Table(dc.Snowflake, Inline_Player); // attachment id or embed_player_key -> player
viewer_url: string; // image viewer overlay (the poster for a GIFV)
viewer_video: string; // GIFV: the looping video
viewer_link: string; // the media menu's target
viewer_size: Int2;
viewer_t: float32;
viewer_msg: dc.Snowflake; // the message the viewer's image is from: its other images are the gallery
viewer_zoom: float32 = 1; // 1 = fit; the wheel zooms at the mouse up to 8x, a click toggles 2x
viewer_pan: Vector2; // the zoomed image's centre from the window's
viewer_pan0: Vector2; // at the press of a drag
viewer_moved: bool; // the press became a drag (not a zoom click)
audio_ready: bool;
video_volume: float32 = 1;
video_muted: bool;
fullscreen_video: dc.Snowflake; // the player shown fullscreen, 0 if none
video_os_full: bool; // fullscreen_video put the window in the OS's fullscreen (media_overlays)
video_os_full_t: float64;

blob_get :: (url: string) -> *Blob {
	b := table_find_pointer(*blobs, url);
	if b && (b.state != .Failed || !retry_due(b.retry)) return b;
	if !b b = find_or_add(*blobs, copy_string(url));
	b.state = .Loading;
	// offline: a decode worker reads FASTCORD_MEDIA_DIR
	c := ifx app.client then media_client(url);
	if c dc.fetch_media(c, .{url = url, kind = .Fetch, visible = true});
	else decode_submit(.{kind = .Fetch, url = copy_string(url)});
	return b;
}

// blob_stream: a video or audio clip downloaded as a <video> element does (range bytes=0-), its player
// reading the bytes as they arrive, so a long clip starts at once (when its index comes first: an MP4 with
// the moov at the end still waits for the whole file). Offline runs read it whole, as blob_get.
blob_stream :: (url: string, kind: dc.Media_Kind, any_host := false) -> *Blob {
	b := table_find_pointer(*blobs, url);
	if b && (b.state != .Failed || !retry_due(b.retry)) return b;
	c := ifx app.client then media_client(url);
	if !c return blob_get(url);
	if !b b = find_or_add(*blobs, copy_string(url));
	b.state = .Loading;
	if b.stream media.growing_release(b.stream); // a failed try's player keeps its own reference
	b.stream = media.growing_create();
	// the head's writer also asks for the tail when an MP4's index comes after its media (growing_tail_wanted)
	s := New(Stream_Fetch);
	s.* = .{g = b.stream, c = c, url = copy_string(url), kind = kind, any_host = any_host};
	take :: (data: *void, piece: []u8) -> bool {
		s := cast(*Stream_Fetch) data;
		if s.g.data.count + piece.count > STREAM_MAX return false; // only this worker grows it
		media.growing_append(s.g, piece);
		off := media.growing_tail_wanted(s.g);
		if off > 0 {
			tail :: (data: *void, piece: []u8) -> bool {
				s := cast(*Stream_Fetch) data;
				if s.g.tail.count + piece.count > STREAM_MAX return false;
				media.growing_append_tail(s.g, piece);
				return true;
			}
			dc.fetch_media(s.c, .{url = s.url, kind = s.kind, visible = true, stream = .{s, tail}, any_host = s.any_host, range_from = off, tag = MEDIA_TAG_TAIL});
		}
		return true;
	}
	dc.fetch_media(c, .{url = url, kind = kind, visible = true, stream = .{s, take}, any_host = any_host});
	return b;
}

// A streamed download's state for its workers (heap, kept: a late tail may still write through it).
Stream_Fetch :: struct { g: *media.Growing_Buffer; c: *dc.Client; url: string; kind: dc.Media_Kind; any_host: bool; }

MEDIA_TAG_TAIL :: 0x6d65_6469_6104;

STREAM_MAX :: 512 << 20;

blob_decoded :: (url: string, data: []u8) {
	b := table_find_pointer(*blobs, url);
	if !b { array_free(data); return; }
	b.data = data;
	b.state = ifx data then Image_State.Ready else .Failed;
}

// Takes a finished media download that belongs to a blob. Returns false if it's not a blob.
blob_receive :: (r: *dc.Media_Result) -> bool {
	b := table_find_pointer(*blobs, r.url);
	if !b return false;
	if b.stream && r.tag == MEDIA_TAG_TAIL {
		media.growing_finish_tail(b.stream, r.status == 200);
		return true;
	}
	if b.stream {
		media.growing_finish(b.stream, r.status == 200);
		b.state = ifx r.status == 200 then Image_State.Ready else .Failed;
	} else if r.status == 200 && r.data {
		b.data = r.data;
		r.data = .[]; // keep ownership
		b.state = .Ready;
	} else {
		b.state = .Failed;
	}
	if b.state == .Failed retry_fail(*b.retry, r.status);
	return true;
}

// A clip whose download failed plays again from a new download once its retry is due: drop its player.
player_retry :: (key: dc.Snowflake) -> *Inline_Player {
	ip := table_find_pointer(*players, key);
	if !ip return null;
	b := table_find_pointer(*blobs, ip.url);
	if !b || b.state != .Failed || !retry_due(b.retry) return ip;
	media.player_destroy(ip.player);
	free(ip.url);
	free(ip.poster);
	table_remove(*players, key);
	return null;
}

// Message attachments: videos, audio, images (GIFs animate), other files as cards; max_w narrows them
// (search results).
attachments_view :: (m: *dc.Message, max_w: float32 = 400) {
	// two or more plain images share one mosaic, as in the client
	grid: [..]int;
	grid.allocator = temp;
	for * a, i: m.attachments if mosaic_image(a) array_add(*grid, i);
	if grid.count >= 2 {
		attachment_mosaic(m, grid, min(max_w, 400));
		spacer(.Y, 4);
	}
	for * a, i: m.attachments {
		if grid.count >= 2 && mosaic_image(a) continue;
		redact := media_redaction(m, a.flags);
		if redact == .Block {
			blocked_media_note(tprint("blocked%", i));
			continue;
		}
		if redact == .Blur && a.width > 0 && a.height > 0 && !table_find_pointer(*revealed_spoilers, a.id) {
			w := cast(float32) a.width;
			h := cast(float32) a.height;
			sc := min(1.0, min(max_w / w, 300 / h));
			if spoiler_cover(tprint("att%", i), attachment_image_url(a, cast(int) (w * sc), cast(int) (h * sc)), w * sc, h * sc, "Sensitive") table_set(*revealed_spoilers, a.id, true);
			spacer(.Y, 4);
		} else if !is_audio(a) && a.width > 0 && a.height > 0 && is_spoiler(a) && !table_find_pointer(*revealed_spoilers, a.id) {
			w := cast(float32) a.width;
			h := cast(float32) a.height;
			sc := min(1.0, min(max_w / w, 300 / h));
			if spoiler_cover(tprint("att%", i), attachment_image_url(a, cast(int) (w * sc), cast(int) (h * sc)), w * sc, h * sc) table_set(*revealed_spoilers, a.id, true);
			spacer(.Y, 4);
		} else if is_spoiler(a) && !table_find_pointer(*revealed_spoilers, a.id) {
			// a file or audio clip: the card's size, with nothing of it shown
			if spoiler_cover(tprint("file%", i), "", min(432.0, max_w + 32), 72) table_set(*revealed_spoilers, a.id, true);
			spacer(.Y, 4);
		} else if is_video(a) && a.width > 0 && a.height > 0 {
			w := cast(float32) a.width;
			h := cast(float32) a.height;
			sc := min(1.0, min(max_w / w, 300 / h));
			// poster frame from the media proxy (?format=webp of a video returns a still)
			video_player(a.id, a.url, attachment_image_url(a, cast(int) (w * sc), cast(int) (h * sc)), w * sc, h * sc, cast(float64) a.duration_secs, download = a);
			spacer(.Y, 4);
		} else if is_audio(a) {
			audio_attachment(a);
			spacer(.Y, 4);
		} else if a.width > 0 && a.height > 0 {
			// images scale to fit 400x300 like the client
			w := cast(float32) a.width;
			h := cast(float32) a.height;
			sc := min(1.0, min(max_w / w, 300 / h));
			img := media_box(tprint("att%", i), attachment_image_url(a, cast(int) (w * sc), cast(int) (h * sc)), "", w * sc, h * sc);
			img.flags |= .Click_On_Release;
			sig := ui.signal(img);
			dragged := drag_out_gesture(sig, a.url, a.filename);
			if sig.clicked && !dragged open_viewer(ifx a.proxy_url then a.proxy_url else a.url, .{a.width, a.height}, link = a.url, msg = m.id);
			if sig.right_clicked media_menu_open(a.url, a.url);
			if a.description {
				ui.parent(img);
				alt := row("alt", .Draw_Background | .Floating_X | .Floating_Y);
				alt.semantic_size = .[ui.children(), ui.px(20)];
				alt.fixed_pos = .{6, h * sc - 26};
				alt.style.bg = .{0, 0, 0, 0.6};
				alt.style.radius = all4(4);
				{ ui.parent(alt); defer ui.pop_parent();
					spacer(.X, 6);
					label("ALT", .Bold, 11, .{1, 1, 1, 1}, 20);
					spacer(.X, 6);
				}
				ui.pop_parent();
				if ui.mouse_over(alt) tooltip_below(a.description, alt.rect);
			}
			spacer(.Y, 4);
		} else if !text_attachment(a, i, max_w) {
			f := row(tprint("file%", i), .Draw_Background | .Draw_Border | .Clickable);
			f.semantic_size = .[ui.px(min(432.0, max_w + 32)), ui.px(72)];
			drag_out_gesture(ui.signal(f), a.url, a.filename);
			f.style.bg = T("--background-surface-high");
			f.style.border_color = T("--border-subtle");
			f.style.border = 1;
			f.style.radius = all4(8);
			{ ui.parent(f); defer ui.pop_parent();
				spacer(.X, 16);
				icon("ficon", "attachment", 30, T("--interactive-icon-default"));
				spacer(.X, 8);
				col := ui.box("fcol");
				col.semantic_size = .[ui.fill(), ui.children()];
				download := false;
				{ ui.parent(col); defer ui.pop_parent();
					name := label(a.filename, .Normal, 16, T("--text-link"), 20);
					name.flags |= .Clickable;
					name.hover_cursor = .Pointer;
					download = ui.signal(name).clicked;
					dl := file_download_find(a.url);
					if dl {
						app.ui.animating = true; // the count moves on the worker
						label(tprint(L("% of %"), human_size(dl.progress.done), human_size(a.size)), .Normal, 12, T("--text-muted"), 16);
						spacer(.Y, 3);
						bar :=ui.box("bar", .Draw_Background);
						bar.semantic_size = .[ui.fill(), ui.px(4)];
						bar.style.bg = T("--background-mod-strong");
						bar.style.radius = all4(2);
						ui.parent(bar);
						fill := ui.box("fill", .Draw_Background | .Floating_X | .Floating_Y);
						fill.semantic_size = .[ui.pct(clamp(cast(float32) dl.progress.done / max(a.size, 1), 0, 1)), ui.px(4)];
						fill.style.bg = T("--background-brand");
						fill.style.radius = all4(2);
						ui.pop_parent();
					} else label(human_size(a.size), .Normal, 12, T("--text-muted"), 16);
				}
				if download_icon() || download file_download(a);
				spacer(.X, 12);
			}
			spacer(.Y, 4);
		}
	}
}

download_icon :: (size: float32 = 24) -> clicked: bool {
	dl := ui.box("dl", .Clickable);
	dl.semantic_size = .[ui.px(size + 8), ui.px(size + 8)];
	dl.hover_cursor = .Pointer;
	sig := ui.signal(dl);
	{ ui.parent(dl); defer ui.pop_parent();
		ic := icon("i", "download", size, T(ifx sig.hovering then "--interactive-icon-hover" else "--interactive-icon-default"), .Floating_X | .Floating_Y);
		ic.fixed_pos = .{4, 4};
	}
	if sig.hovering tooltip_below(L("Download"), dl.rect);
	return sig.clicked;
}

// A text or code file under TEXT_PREVIEW_MAX shows inline as a code box, highlighted by its extension:
// the first TEXT_LINES lines, Expand for up to TEXT_LINES_OPEN, its name, size and download above. False
// (the plain file card) while it loads, when it fails, or when it isn't text after all.
TEXT_PREVIEW_MAX :: 512 << 10;
TEXT_LINES :: 6;
TEXT_LINES_OPEN :: 100;

text_attachment :: (a: *dc.Attachment, i: int, max_w: float32) -> bool {
	ext := url_ext(a.filename);
	if a.size <= 0 || a.size > TEXT_PREVIEW_MAX return false;
	if !begins_with(a.content_type, "text/") && hl_lang(ext) == HL_NONE && !array_find(string.["txt", "log", "md", "csv", "ini", "cfg", "conf"], ext) return false;
	blob := blob_get(a.url);
	if blob.state != .Ready return false;
	text := cast(string) blob.data;
	text.count = min(text.count, TEXT_PREVIEW_MAX); // the server may send more than it said
	if !text || find_index_from_left(text, #char "\0") >= 0 return false;
	open := array_find(text_open, a.id);
	shown, lines := text, 0;
	for cast([]u8) text if it == #char "\n" {
		lines += 1;
		if lines == ifx open then TEXT_LINES_OPEN else TEXT_LINES shown.count = min(shown.count, it_index);
	}
	if text[text.count - 1] != #char "\n" lines += 1;
	if shown && shown[shown.count - 1] == #char "\n" shown.count -= 1;
	card := ui.box(tprint("text%", i), .Draw_Background | .Draw_Border);
	card.semantic_size = .[ui.px(min(432.0, max_w + 32)), ui.children()];
	card.layout_axis = .Y;
	card.style.bg = T("--background-base-lowest");
	card.style.border_color = T("--border-subtle");
	card.style.border = 1;
	card.style.radius = all4(8);
	{ ui.parent(card); defer ui.pop_parent();
		head := row("head");
		head.semantic_size = .[ui.pct(1), ui.px(40)];
		{ ui.parent(head); defer ui.pop_parent();
			spacer(.X, 12);
			name := label(a.filename, .Medium, 14, T("--text-link"), 18);
			name.flags |= .Clickable;
			name.hover_cursor = .Pointer;
			spacer(.X, 8);
			dl := file_download_find(a.url);
			label(ifx dl then tprint(L("% of %"), human_size(dl.progress.done), human_size(a.size)) else human_size(a.size), .Normal, 12, T("--text-muted"), 16);
			if dl app.ui.animating = true;
			gap := ui.box("gap");
			gap.semantic_size = .[ui.fill(), ui.px(1)];
			if download_icon(20) || ui.signal(name).clicked file_download(a);
			spacer(.X, 6);
		}
		code := ui.box("code", .Draw_Text | .Selectable_Text | .Wrap_Text);
		ui.set_spans(code, code_spans(shown, ext, F(.Mono), 13));
		code.semantic_size = .[ui.pct(1), ui.text_size()];
		code.style.font = F(.Mono);
		code.style.font_size = 13;
		code.style.line_height = 18;
		code.style.padding = .{12, 4};
		code.style.text_color = T("--text-code");
		if lines > TEXT_LINES {
			more := row("more", .Clickable);
			more.semantic_size = .[ui.pct(1), ui.px(32)];
			more.hover_cursor = .Pointer;
			sig := ui.signal(more);
			ui.parent(more); defer ui.pop_parent();
			spacer(.X, 12);
			color := T(ifx sig.hovering then "--interactive-icon-hover" else "--interactive-icon-default");
			icon("chev", ifx open then "chevron-small-up" else "chevron-small-down", 16, color);
			spacer(.X, 4);
			label(ifx open then L("Collapse") else ifx lines > TEXT_LINES_OPEN then tprint(L("Expand (% of % lines)"), TEXT_LINES_OPEN, lines) else tprint(L("Expand (% lines)"), lines), .Medium, 13, color, 16);
			if sig.clicked {
				if open array_unordered_remove_by_value(*text_open, a.id);
				else array_add(*text_open, a.id);
			}
		} else spacer(.Y, 8);
	}
	spacer(.Y, 4);
	return true;
}

text_open: [..]dc.Snowflake; // text previews expanded, by attachment id

// Dragging an image or file out of the window hands over the file (platform.drag_out; macOS so far): its
// bytes are fetched only where it's dropped, by drag_write. True once the press became such a drag, so
// its release isn't a click.
drag_out_gesture :: (sig: ui.Signal, url: string, name: string) -> bool {
	if sig.pressed drag_out_started = false;
	if sig.dragging && !drag_out_started && abs(sig.drag_delta.x) + abs(sig.drag_delta.y) >= 8 {
		drag_out_started = true;
		drag_client = ifx app.client then media_client(url);
		platform.drag_out(url, name, drag_write);
	}
	return drag_out_started;
}

drag_out_started: bool;
drag_client: *dc.Client; // the dragged file's connection, set on the UI thread before the drag

// drag_write: platform.Drag_Write, on the drop's queue (not the UI thread): the file as the page loads it.
drag_write :: (url: string, path: string) -> bool {
	if !drag_client return false;
	image := array_find(string.["png", "jpg", "jpeg", "gif", "webp", "avif", "bmp"], url_ext(url));
	status, _, _, body := dc.media_get(drag_client, url, ifx image then dc.Media_Kind.Image else .Fetch, false, "");
	return status == 200 && body.count > 0 && write_entire_file(path, body.data, body.count);
}

is_video ::(a: *dc.Attachment) -> bool { return begins_with(a.content_type, "video/"); }

// A plain image (not a video, audio clip or spoiler): what joins a message's mosaic.
mosaic_image :: (a: *dc.Attachment) -> bool { return !is_video(a) && !is_audio(a) && !is_spoiler(a) && !(a.flags & MEDIA_FLAGGED) && a.width > 0 && a.height > 0; }

// Explicit and gore media: the content scan's flags (attachments' and embeds' alike) against the synced
// Content Filters for this kind of channel (servers, friends' DMs, others' DMs). Unset: blur everywhere
// without NSFW access, else block in others' DMs (as analytics_redactable_page reads it). Never ours.
MEDIA_EXPLICIT : u64 : 16;
MEDIA_GORE : u64 : 64;
MEDIA_FLAGGED :: MEDIA_EXPLICIT | MEDIA_GORE;
Redaction :: enum u8 { Show; Blur; Block; }

media_redaction :: (m: *dc.Message, flags: u64) -> Redaction {
	s := store();
	if !(flags & MEDIA_FLAGGED) || m.author_id == s.me return .Show;
	ch := dc.channel_get(s, m.channel_id);
	kind := 0;
	if ch && !ch.guild_id {
		_, rel := table_find(*s.relationships, m.author_id);
		kind = ifx rel.kind == .Friend then 1 else 2;
	}
	out := Redaction.Show;
	for harm: 0..1 {
		if !(flags & (ifx harm then MEDIA_GORE else MEDIA_EXPLICIT)) continue;
		v := s.settings.media_redaction[harm][kind];
		if v == 0 v = cast(u64) ifx s.settings.nsfw_blocked then 2 else ifx kind == 2 then 3 else 1;
		if v == 3 return .Block;
		if v == 2 out = .Blur;
	}
	return out;
}

// In place of media the Content Filters block.
blocked_media_note :: (id: string) {
	label(tprint("Blocked by your content filters##%", id), .Normal, 14, T("--text-muted"), 20);
	spacer(.Y, 4);
}

// Several images as the client's mosaic, gw wide with 4 px gaps: rows of 2 and 3 (5: 2+3, 6: 3+3,
// 8: 2+3+3, 9: 3x3), a lone first row on top for 7 and 10, and 3 as one large tile beside two
// stacked. Tiles crop their image to fill; a click opens the viewer on the message's images.
attachment_mosaic :: (m: *dc.Message, idx: []int, gw: float32) {
	GAP :: 4;
	tile :: (k: int, w: float32, h: float32) #expand {
		a := *m.attachments[idx[k]];
		img := media_box(tprint("mos%", k), attachment_image_url(a, cast(int) w, cast(int) h), "", w, h);
		set_remote_image(img, attachment_image_url(a, cast(int) w, cast(int) h), cover = true);
		img.flags |= .Click_On_Release;
		sig := ui.signal(img);
		dragged := drag_out_gesture(sig, a.url, a.filename);
		if sig.clicked && !dragged open_viewer(ifx a.proxy_url then a.proxy_url else a.url, .{a.width, a.height}, link = a.url, msg = m.id);
		if sig.right_clicked media_menu_open(a.url, a.url);
	}
	n := min(idx.count, 10);
	box := ui.box("mosaic");
	box.semantic_size = .[ui.px(gw), ui.children()];
	box.layout_axis = .Y;
	ui.parent(box); defer ui.pop_parent();
	if n == 3 {
		r := row("r3");
		big := (gw - GAP) * 2 / 3;
		small := gw - GAP - big;
		r.semantic_size = .[ui.px(gw), ui.px(big)];
		ui.parent(r); defer ui.pop_parent();
		tile(0, big, big);
		spacer(.X, GAP);
		col := ui.box("c");
		col.semantic_size = .[ui.px(small), ui.px(big)];
		col.layout_axis = .Y;
		ui.parent(col); defer ui.pop_parent();
		tile(1, small, (big - GAP) / 2);
		spacer(.Y, GAP);
		tile(2, small, (big - GAP) / 2);
		return;
	}
	ROWS :: ([]int).[.[], .[], .[2], .[], .[2, 2], .[2, 3], .[3, 3], .[1, 3, 3], .[2, 3, 3], .[3, 3, 3], .[1, 3, 3, 3]];
	k := 0;
	for cols, ri: ROWS[n] {
		if ri spacer(.Y, GAP);
		tw := (gw - GAP * (cols - 1)) / cols;
		th := ifx cols == 1 then gw * 0.5625 else tw; // a lone tile 16:9, the rest square
		r := row(tprint("r%", ri));
		r.semantic_size = .[ui.px(gw), ui.px(th)];
		ui.parent(r); defer ui.pop_parent();
		for c: 0..cols - 1 {
			if c spacer(.X, GAP);
			tile(k, tw, th);
			k += 1;
		}
	}
}
is_spoiler :: (a: *dc.Attachment) -> bool { return begins_with(a.filename, "SPOILER_") || (a.flags & 8) != 0; }

// A spoilered attachment: the image blurred (url "" for a file: a plain box) under a "SPOILER" pill until
// clicked. True when clicked.
spoiler_cover :: (id: string, url: string, w: float32, h: float32, text := "SPOILER") -> bool {
	b := ui.box(id, .Draw_Background | .Clickable);
	b.semantic_size = .[ui.px(w), ui.px(h)];
	b.style.radius = all4(8);
	b.style.bg = T("--background-mod-strong");
	set_remote_image(b, url, blur = true);
	b.hover_cursor = .Pointer;
	sig := ui.signal(b);
	ui.parent(b); defer ui.pop_parent();
	pill := row("spoiler", .Draw_Background | .Floating_X | .Floating_Y);
	pill.semantic_size = .[ui.px(88), ui.px(32)];
	pill.fixed_pos = .{(w - 88) / 2, (h - 32) / 2};
	pill.style.bg = ifx sig.hovering then ui.Color.{0, 0, 0, 0.9} else .{0, 0, 0, 0.6};
	pill.style.radius = all4(16);
	{ ui.parent(pill); defer ui.pop_parent();
		filler(.X);
		label(text, .Bold, 15, .{1, 1, 1, 1}, 32);
		filler(.X);
	}
	return sig.clicked;
}
is_audio :: (a: *dc.Attachment) -> bool { return begins_with(a.content_type, "audio/"); }

// Video attachment or embed video: poster with a play button and the control bar (play, time, seek,
// volume, fullscreen) until clicked, then plays inline; the bar hides while it plays unhovered. key names
// its player (an attachment id, or embed_player_key); full draws it in the fullscreen overlay.
video_player :: (key: dc.Snowflake, url: string, poster: string, w: float32, h: float32, duration: float64 = 0, full := false, any_host := false, autostart := false, download: *dc.Attachment = null) -> *ui.Box {
	box := ui.box(tprint("vid%", cast(u64) key), .Draw_Background | .Clickable | .Clip);
	box.semantic_size = .[ui.px(w), ui.px(h)];
	box.style.radius = all4(ifx full then 0.0 else 8.0);
	box.style.bg = .{0, 0, 0, 1};
	sig := ui.signal(box);
	ip := ifx full then table_find_pointer(*players, key) else player_retry(key); // full: url is ip.url
	start :: () #expand {
		if `ip return;
		blob_stream(url, .Video, any_host);
		`ip = table_set(*players, key, .{url = copy_string(url), poster = copy_string(poster), size = .{w, h}});
	}
	if autostart start();
	p := ifx ip then ip.player else null;
	if p && (full || fullscreen_video != key) {
		player_open_ready(ip);
		img := media.player_update(p);
		if img.y != 0 ip.img = img;
		if media.player_is_playing(p) app.ui.animating = true;
		box.custom_draw = video_draw;
		box.custom_user = cast(*void) cast(u64) key;
		if sig.clicked media.player_toggle(p);
	} else {
		if ip player_open_ready(ip);
		set_remote_image(box, poster);
		if sig.clicked start();
	}
	if sig.double_clicked {
		start();
		fullscreen_video = ifx full then 0 else key;
	}
	playing := p != null && media.player_is_playing(p);
	{ ui.parent(box); defer ui.pop_parent();
		if !playing {
			pb := ui.box("play", .Draw_Background | .Floating_X | .Floating_Y);
			pb.semantic_size = .[ui.px(48), ui.px(48)];
			pb.fixed_pos = .{(w - 48) / 2, (h - 48) / 2};
			pb.style.radius = all4(24);
			pb.style.bg = .{0, 0, 0, 0.6};
			{ ui.parent(pb); defer ui.pop_parent();
				pi := ui.box("i", .Floating_X | .Floating_Y);
				pi.semantic_size = .[ui.px(24), ui.px(24)];
				pi.fixed_pos = .{13, 12};
				set_icon(pi, "play", .{1, 1, 1, 1});
			}
		}
		// children take the hover, so test the box's rect
		if playing && !ui.contains(box.rect, app.ui.mouse) return box;
		white := ui.Color.{1, 1, 1, 1};
		bar := row("controls", .Draw_Background | .Floating_X | .Floating_Y);
		bar.semantic_size = .[ui.px(w), ui.px(40)];
		bar.fixed_pos = .{0, h - 40};
		bar.style.bg = .{0, 0, 0, 0.6};
		ui.parent(bar); defer ui.pop_parent();
		spacer(.X, 6);
		if video_button("pp", ifx playing then "pause" else "play") {
			if p media.player_toggle(p);
			else start();
		}
		pos := ifx p then media.player_position(p) else 0;
		dur := ifx p then media.player_duration(p) else duration;
		spacer(.X, 4);
		label(tprint("% / %", fmt_clock(pos), ifx dur > 0 then fmt_clock(dur) else "-:--"), .Mono, 13, white, 16);
		spacer(.X, 12);
		seek := slider("seek", ifx dur > 0 then cast(float32) (pos / dur) else 0, ui.fill());
		if p && seek >= 0 media.player_seek(p, cast(float64) seek * dur);
		spacer(.X, 8);
		// volume: the icon mutes; hovering the group shows its slider
		vg := row("vol");
		vg.semantic_size = .[ui.children(), ui.px(32)];
		hover_vol := ui.contains(vg.rect, app.ui.mouse);
		{ ui.parent(vg); defer ui.pop_parent();
			if hover_vol {
				// 0-400% (the client stops at 100%); the mixer's limiter keeps the boost from clipping
				v := slider("vs", ifx video_muted then 0 else video_volume / 4, ui.px(96));
				if v >= 0 video_volume_set(v * 4, v == 0);
				spacer(.X, 4);
			}
			if video_button("mute", ifx video_muted || video_volume == 0 then "speaker-slash" else "voice-normal") video_volume_set(ifx video_volume == 0 then 1 else video_volume, !video_muted);
		}
		if download && video_button("dl", "download") file_download(download); // an attachment: the file itself
		if video_button("full", "fullscreen") {
			start();
			fullscreen_video = ifx full then 0 else key;
		}
		spacer(.X, 6);
	}
	return box;
}

video_button :: (id: string, name: string) -> bool {
	b := ui.box(id, .Clickable);
	b.semantic_size = .[ui.px(32), ui.px(32)];
	sig := ui.signal(b);
	ui.parent(b); defer ui.pop_parent();
	ic := icon("i", name, 20, .{1, 1, 1, ifx sig.hovering then 1.0 else 0.8}, .Floating_X | .Floating_Y);
	ic.fixed_pos = .{6, 6};
	return sig.clicked;
}

// A thin white track filled with the brand colour to frac; returns the new fraction while pressed or
// dragged, else -1.
slider :: (id: string, frac: float32, size: ui.Size) -> float32 {
	track := ui.box(id, .Clickable);
	track.semantic_size = .[size, ui.px(16)];
	sig := ui.signal(track);
	tw := track.rect.x1 - track.rect.x0;
	ui.parent(track); defer ui.pop_parent();
	bg := ui.box("bg", .Draw_Background | .Floating_X | .Floating_Y);
	bg.semantic_size = .[ui.px(tw), ui.px(6)];
	bg.fixed_pos = .{0, 5};
	bg.style.bg = .{1, 1, 1, 0.3};
	bg.style.radius = all4(3);
	fill := ui.box("fill", .Draw_Background | .Floating_X | .Floating_Y);
	fill.semantic_size = .[ui.px(tw * clamp(frac, 0, 1)), ui.px(6)];
	fill.fixed_pos = .{0, 5};
	fill.style.bg = T("--background-brand");
	fill.style.radius = all4(3);
	if !(sig.pressed || sig.dragging) || tw <= 0 return -1;
	return clamp((app.ui.mouse.x - track.rect.x0) / tw, 0, 1);
}

// One volume for every video, like the client's single media volume.
video_volume_set :: (v: float32, muted: bool) {
	video_volume, video_muted = v, muted;
	for * players if it.player {
		media.player_set_volume(it.player, v);
		media.player_set_muted(it.player, muted);
	}
}

// The fullscreen player: the window black, the video fit to it; Escape or its button leaves.
video_fullscreen :: () {
	ip := table_find_pointer(*players, fullscreen_video);
	if !ip {
		fullscreen_video = 0;
		return;
	}
	scrim := ui.box("video_full", .Draw_Background | .Clickable | .Floating_X | .Floating_Y | .Overlay);
	scrim.semantic_size = .[ui.px(app.ui.window.x), ui.px(app.ui.window.y)];
	scrim.style.bg = .{0, 0, 0, 1};
	ui.signal(scrim);
	{ ui.parent(scrim); defer ui.pop_parent();
		sc := min(app.ui.window.x / max(ip.size.x, 1), app.ui.window.y / max(ip.size.y, 1));
		w, h := ip.size.x * sc, ip.size.y * sc;
		v := video_player(fullscreen_video, ip.url, ip.poster, w, h, full = true);
		v.flags |= .Floating_X | .Floating_Y;
		v.fixed_pos = .{(app.ui.window.x - w) / 2, (app.ui.window.y - h) / 2};
	}
	for * app.ui.events if it.kind == .Key_Down && it.key == .Escape { fullscreen_video = 0; it.consumed = true; }
}

ensure_audio :: () {
	if audio_ready return;
	audio_ready = audio.init();
	if !audio_ready {
		audio.init_null();
		audio_ready = true;
	}
}

// Audio attachment (and voice messages): file card with play button and progress.
audio_attachment :: (a: *dc.Attachment) {
	card := row(tprint("aud%", cast(u64) a.id), .Draw_Background | .Draw_Border);
	card.semantic_size = .[ui.px(400), ui.px(56)];
	card.style.bg = T("--background-surface-high");
	card.style.border_color = T("--border-subtle");
	card.style.border = 1;
	card.style.radius = all4(8);
	ip := player_retry(a.id);
	playing := ip != null;
	if playing player_open_ready(ip);
	{ ui.parent(card); defer ui.pop_parent();
		spacer(.X, 12);
		pb := ui.box("play", .Clickable | .Draw_Background | .Hot_Animation);
		pb.semantic_size = .[ui.px(32), ui.px(32)];
		pb.style.radius = all4(16);
		pb.style.bg = T("--background-brand");
		pb.style.bg_hot = with_alpha(T("--background-brand"), 0.85);
		is_playing := playing && ip.player != null && media.player_is_playing(ip.player);
		{ ui.parent(pb); defer ui.pop_parent();
			pi := ui.box("i", .Floating_X | .Floating_Y);
			pi.semantic_size = .[ui.px(18), ui.px(18)];
			pi.fixed_pos = .{7, 7};
			set_icon(pi, ifx is_playing then "pause" else "play", .{1, 1, 1, 1});
		}
		if ui.signal(pb).clicked {
			if !playing {
				blob_stream(a.url, .Audio);
				table_set(*players, a.id, .{url = copy_string(a.url), voice = a.waveform != ""});
			} else if ip.player {
				media.player_toggle(ip.player);
			}
		}
		spacer(.X, 12);
		pos, dur: float64;
		if playing && ip.player != null {
			pos = media.player_position(ip.player);
			dur = media.player_duration(ip.player);
			if is_playing app.ui.animating = true;
		} else {
			dur = cast(float64) a.duration_secs;
		}
		wave, ok := base64_decode(a.waveform,, temp);
		if ok && wave.count {
			voice_waveform(wave, ifx dur > 0 then cast(float32) (pos / dur) else 0, ip, dur);
			spacer(.X, 12);
			label(fmt_clock(ifx playing then max(dur - pos, 0) / voice_rate else dur), .Mono, 12, T("--text-muted"), 16);
			spacer(.X, 8);
			// playback speed: 1x, 1.5x, 2x, then back
			rb := ui.box(tprint("%x##rate", voice_rate), .Clickable | .Draw_Background | .Draw_Text | .Hot_Animation);
			rb.semantic_size = .[ui.px(36), ui.px(22)];
			rb.style.radius = all4(11);
			rb.style.bg = T("--background-mod-normal");
			rb.style.bg_hot = T("--background-mod-strong");
			rb.style.font = F(.Semibold);
			rb.style.font_size = 12;
			rb.style.text_align = .Center;
			rb.style.text_color = T("--text-default");
			if ui.signal(rb).clicked {
				voice_rate = ifx voice_rate == 1 then 1.5 else ifx voice_rate == 1.5 then 2.0 else 1.0;
				if playing && ip.player media.player_set_rate(ip.player, voice_rate);
			}
			spacer(.X, 12);
			return;
		}
		col := ui.box("col");
		col.semantic_size = .[ui.fill(), ui.children()];
		{ ui.parent(col); defer ui.pop_parent();
			// the name, its size and a download, as the client's audio card
			nr := row("name");
			nr.semantic_size = .[ui.pct(1), ui.px(20)];
			{ ui.parent(nr); defer ui.pop_parent();
				name := label(a.filename, .Medium, 14, T("--text-link"), 18);
				name.flags |= .Clickable;
				name.hover_cursor = .Pointer;
				spacer(.X, 6);
				dl := file_download_find(a.url);
				label(ifx dl then tprint(L("% of %"), human_size(dl.progress.done), human_size(a.size)) else human_size(a.size), .Normal, 12, T("--text-muted"), 16);
				if dl app.ui.animating = true;
				filler(.X);
				if download_icon(16) || ui.signal(name).clicked file_download(a);
			}
			// time, the seek bar once loaded, and the shared media volume (as on videos)
			tr := row("time");
			tr.semantic_size = .[ui.pct(1), ui.px(18)];
			ui.parent(tr); defer ui.pop_parent();
			label(tprint("% / %", fmt_clock(pos), fmt_clock(dur)), .Normal, 12, T("--text-muted"), 16);
			spacer(.X, 8);
			seek := slider("seek", ifx dur > 0 then cast(float32) (pos / dur) else 0, ui.fill());
			if seek >= 0 && playing && ip.player && dur > 0 media.player_seek(ip.player, cast(float64) seek * dur);
			spacer(.X, 8);
			if ui.contains(tr.rect, app.ui.mouse) {
				v := slider("vs", ifx video_muted then 0 else video_volume / 4, ui.px(64));
				if v >= 0 video_volume_set(v * 4, v == 0);
				spacer(.X, 4);
			}
			mb := ui.box("mute", .Clickable);
			mb.semantic_size = .[ui.px(18), ui.px(18)];
			msig := ui.signal(mb);
			set_icon(mb, ifx video_muted || video_volume == 0 then "speaker-slash" else "voice-normal", ifx msig.hovering then T("--interactive-icon-hover") else T("--interactive-icon-default"));
			if msig.clicked video_volume_set(ifx video_volume == 0 then 1 else video_volume, !video_muted);
		}
		spacer(.X, 12);
	}
}

// A voice message's amplitudes (0-255) as rounded bars, the played part in the brand colour; pressing
// or dragging seeks once the clip is loaded.
voice_waveform :: (wave: string, frac: float32, ip: *Inline_Player, dur: float64) {
	BARS :: 48;
	PITCH :: 5.0;
	w := ui.box("wave", .Clickable);
	w.semantic_size = .[ui.px(BARS * PITCH), ui.px(32)];
	w.hover_cursor = .Pointer;
	sig := ui.signal(w);
	if (sig.pressed || sig.dragging) && ip && ip.player && dur > 0 {
		f := clamp((app.ui.mouse.x - w.rect.x0) / (BARS * PITCH), 0, 1);
		media.player_seek(ip.player, cast(float64) f * dur);
	}
	ui.parent(w); defer ui.pop_parent();
	for i: 0..BARS - 1 {
		lo := i * wave.count / BARS;
		hi := max((i + 1) * wave.count / BARS, lo + 1);
		peak: u8;
		for j: lo..hi - 1 peak = max(peak, wave[j]);
		h := max(4.0, 28.0 * peak / 255.0);
		b := ui.box(tprint("b%", i), .Draw_Background | .Floating_X | .Floating_Y);
		b.semantic_size = .[ui.px(3), ui.px(h)];
		b.fixed_pos = .{i * PITCH, (32 - h) / 2};
		b.style.radius = all4(1.5);
		b.style.bg = ifx (i + 0.5) / BARS <= frac then T("--background-brand") else T("--icon-muted");
	}
}

// Link embeds: colored left bar, provider/author/title/description, image or thumbnail.
embeds_view :: (m: *dc.Message, max_w: float32 = 400) {
	if m.flags & 4 return; // SUPPRESS_EMBEDS
	for * e, i: m.embeds {
		// a free emoji link's image already shows inline, as the emoji (markdown.jai free_emoji_link)
		_, _, free := free_emoji_link(e.url);
		if free && e.kind == "image" && contains(m.content, tprint("](%", e.url)) continue;
		redact := media_redaction(m, e.flags);
		if redact == .Block { blocked_media_note(tprint("eblocked%", i)); continue; }
		ekey := cast(u64) m.id + cast(u64) i + 1; // revealed_spoilers' key for this embed
		if redact == .Blur && !table_find_pointer(*revealed_spoilers, ekey) {
			url := ifx e.thumbnail_url != "" then e.thumbnail_url else e.image_url;
			w := cast(float32) max(max(e.thumbnail_w, e.image_w), 160);
			h := cast(float32) max(max(e.thumbnail_h, e.image_h), 90);
			sc := min(1.0, min(max_w / w, 300 / h));
			if spoiler_cover(tprint("eblur%", i), url, w * sc, h * sc, "Sensitive") table_set(*revealed_spoilers, ekey, true);
			spacer(.Y, 4);
			continue;
		}
		if e.kind == "gifv" || (e.kind == "image" && e.title == "") {
			// bare media links render as the media itself; GIFV (Tenor, Klipy) as its looping video
			url := ifx e.thumbnail_url != "" then e.thumbnail_url else e.image_url;
			w := cast(float32) max(e.thumbnail_w, e.image_w);
			h := cast(float32) max(e.thumbnail_h, e.image_h);
			if url == "" || w <= 0 || h <= 0 continue;
			sc := min(1.0, min(max_w / w, 300 / h));
			video := ifx e.kind == "gifv" then e.video_url else "";
			img := media_box(tprint("emedia%", i), url, video, w * sc, h * sc);
			sig := ui.signal(img);
			if sig.clicked open_viewer(url, .{cast(int) w, cast(int) h}, video, e.url, m.id);
			// the client's image items need an <img>: a GIFV video gets the link items only
			if sig.right_clicked media_menu_open(e.url, ifx video then "" else url);
			spacer(.Y, 4);
			continue;
		}
		// images of later embeds with this url join this one's grid (a post with several images)
		if e.url != "" && e.image_url != "" && i > 0 {
			merged := false;
			for j: 0..i - 1 if m.embeds[j].url == e.url && m.embeds[j].image_url != "" { merged = true; break; }
			if merged continue;
		}
		images: [..]*dc.Embed;
		images.allocator = temp;
		if e.image_url != "" && e.image_w > 0 for * o, j: m.embeds if j >= i && o.url == e.url && o.image_url != "" && o.image_w > 0 && images.count < 4 {
			array_add(*images, o);
			if e.url == "" break;
		}
		video := is_discord_media(e.video_url) && (e.video_w > 0 || e.thumbnail_w > 0);
		// any other video embed (YouTube's iframe url): its thumbnail large, opening the link
		poster := !video && e.kind == "video" && e.thumbnail_url != "" && e.thumbnail_w > 0;
		card := row(tprint("embed%", i), .Draw_Background);
		card.semantic_size = .[ui.px(min(432.0, max_w + 32)), ui.children()];
		card.cross_align = .Start;
		card.style.bg = T("--embed-background");
		card.style.radius = all4(4);
		{ ui.parent(card); defer ui.pop_parent();
			bar := ui.box("bar", .Draw_Background | .Floating_X | .Floating_Y);
			bar.semantic_size = .[ui.px(4), ui.px(card.rect.y1 - card.rect.y0)];
			bar.style.radius = .[4, 0, 4, 0];
			bar.style.bg = ifx e.color != 0 then rgb_u32(e.color) else T("--border-strong");
			spacer(.X, 16);
			col := ui.box("col");
			col.semantic_size = .[ui.fill(), ui.children()];
			col.layout_axis = .Y;
			{ ui.parent(col); defer ui.pop_parent();
				spacer(.Y, 8);
				if e.provider embed_link_text("prov", e.provider, e.provider_url, .Normal, 12, T("--text-muted"), m);
				if e.author_name != "" {
					spacer(.Y, 4);
					ar := row("author");
					ar.semantic_size = .[ui.pct(1), ui.children()];
					ar.cross_align = .Center;
					ui.parent(ar); defer ui.pop_parent();
					if e.author_icon { embed_icon("aicon", e.author_icon, 24); spacer(.X, 8); }
					embed_link_text("aname", e.author_name, e.author_url, .Semibold, 14, T("--text-strong"), m);
				}
				if e.title != "" {
					spacer(.Y, 4);
					t := ui.box("title", .Wrap_Text | .Selectable_Text);
					t.semantic_size = .[ui.pct(1), ui.text_size()];
					t.style.line_height = 22;
					t.sel_order = cast(u64) m.id * 8 + 6;
					// a linked title: the hand and an underline on hover, a click follows it
					over := e.url != "" && ui.mouse_over(t) && ui.span_at(t.prev_layout, app.ui.mouse) >= 0 && !ui.overlay_at(app.ui.mouse);
					ui.set_spans(t, ui.Span.[.{text = e.title, font = F(.Semibold), size = 16, color = ifx e.url != "" then T("--text-link") else T("--text-strong"), underline = over}]);
					if over {
						app.ui.span_cursor = .Pointer;
						for app.ui.events if it.kind == .Mouse_Up && it.button == .Left && !it.consumed && !ui.has_selection() && ui.span_at(t.prev_layout, it.pos) >= 0 follow_link(e.url, m.id);
					}
				}
				if e.description != "" {
					spacer(.Y, 8);
					embed_markdown("d", e.description, m, 0);
				}
				fi := 0;
				if e.fields.count spacer(.Y, 8);
				while fi < e.fields.count {
					// Up to 3 inline fields in a row share it evenly; any other field takes a row alone.
					n := 1;
					if e.fields[fi].is_inline while n < 3 && fi + n < e.fields.count && e.fields[fi + n].is_inline n += 1;
					fr := row(tprint("frow%", fi));
					fr.semantic_size = .[ui.pct(1), ui.children()];
					fr.cross_align = .Start;
					{ ui.parent(fr); defer ui.pop_parent();
						for k: 0..n - 1 {
							f := *e.fields[fi + k];
							if k spacer(.X, 8);
							fc := ui.box(tprint("f%", fi + k));
							fc.semantic_size = .[ui.fill(), ui.children()];
							fc.layout_axis = .Y;
							ui.parent(fc); defer ui.pop_parent();
							name := ui.box("n", .Wrap_Text);
							name.semantic_size = .[ui.pct(1), ui.text_size()];
							name.style.line_height = 18;
							ui.set_spans(name, ui.Span.[.{text = f.name, font = F(.Semibold), size = 14, color = T("--text-strong")}]);
							spacer(.Y, 2);
							embed_markdown("v", f.value, m, (fi + k + 1) * 1000);
						}
					}
					spacer(.Y, 8);
					fi += n;
				}
				if video {
					// a proxied video (FxTwitter, Reddit…) plays in the card; YouTube's iframe url doesn't
					spacer(.Y, 16);
					w := cast(float32) ifx e.video_w > 0 then e.video_w else e.thumbnail_w;
					h := cast(float32) ifx e.video_h > 0 then e.video_h else e.thumbnail_h;
					sc := min(1.0, min(max_w / w, 300 / h));
					video_player(embed_player_key(m, i), e.video_url, e.thumbnail_url, w * sc, h * sc);
				} else if poster && yt_ready(e.url) {
					// played through yt-dlp (youtube.jai)
					spacer(.Y, 16);
					w := cast(float32) e.thumbnail_w;
					h := cast(float32) e.thumbnail_h;
					sc := min(max_w / w, 300 / h);
					video_player(embed_player_key(m, i), youtube_find(e.url).stream, e.thumbnail_url, w * sc, h * sc, any_host = true, autostart = true);
				} else if poster {
					spacer(.Y, 16);
					w := cast(float32) e.thumbnail_w;
					h := cast(float32) e.thumbnail_h;
					sc := min(max_w / w, 300 / h);
					yt := ifx is_youtube(e.url) then youtube_find(e.url) else null;
					if yt && atomic_load(*yt.state) == .Failed && !yt.failed_seen {
						yt.failed_seen = true;
						toast_show(L("Couldn't play it here, so it opened in your browser."), false);
						open_url(e.url);
					}
					th := media_box("poster", e.thumbnail_url, "", w * sc, h * sc);
					th.style.radius = all4(4);
					{ ui.parent(th); defer ui.pop_parent();
						pb := ui.box("play", .Draw_Background | .Floating_X | .Floating_Y);
						pb.semantic_size = .[ui.px(48), ui.px(48)];
						pb.fixed_pos = .{(w * sc - 48) / 2, (h * sc - 48) / 2};
						pb.style.radius = all4(24);
						pb.style.bg = .{0, 0, 0, 0.6};
						ic := icon("i", "play", 24, .{1, 1, 1, 1}, .Floating_X | .Floating_Y);
						ic.fixed_pos = .{(w * sc - 24) / 2 + 1, (h * sc - 24) / 2};
					}
					if yt && atomic_load(*yt.state) == .Resolving {
						ui.parent(th); defer ui.pop_parent();
						l := row("finding", .Draw_Background | .Floating_X | .Floating_Y);
						l.semantic_size = .[ui.children(), ui.px(24)];
						l.fixed_pos = .{8, h * sc - 32};
						l.style.bg = .{0, 0, 0, 0.6};
						l.style.radius = all4(4);
						app.ui.animating = true;
						ui.parent(l); defer ui.pop_parent();
						spacer(.X, 8);
						label(tprint(L("Finding the video%"), string.["", ".", "..", "..."][cast(int) (app.ui.time * 3) % 4]), .Medium, 12, .{1, 1, 1, 1}, 16);
						spacer(.X, 8);
					}
					sig := ui.signal(th);
					if sig.clicked {
						if !is_youtube(e.url) || youtube_ytdlp == YT_OFF open_url(e.url);
						else if youtube_ytdlp == YT_ON youtube_play(e.url);
						else yt_ask = embed_player_key(m, i);
					}
					if sig.right_clicked media_menu_open(e.url, "");
					if yt_ask == embed_player_key(m, i) {
						// the first play asks once whether to use the user's own yt-dlp
						spacer(.Y, 8);
						q := ui.box("ytask", .Draw_Text | .Wrap_Text);
						q.semantic_size = .[ui.px(w * sc), ui.text_size()];
						ui.set_spans(q, ui.Span.[.{text = "Play YouTube videos here with yt-dlp? It needs yt-dlp installed, and connects to YouTube from your computer. Settings > Chat can change this.", font = F(.Normal), size = 13, color = T("--text-muted")}]);
						spacer(.Y, 8);
						br := row("ytbtns");
						br.semantic_size = .[ui.children(), ui.px(32)];
						ui.parent(br); defer ui.pop_parent();
						if set_button(L("Play Here##ytyes"), .Primary, true, 32) { youtube_ytdlp = YT_ON; yt_ask = 0; youtube_play(e.url); }
						spacer(.X, 8);
						if set_button(L("Open in YouTube##ytno"), .Secondary, true, 32) { youtube_ytdlp = YT_OFF; yt_ask = 0; open_url(e.url); }
					}
				} else if images.count == 1 {
					spacer(.Y, 16);
					w := cast(float32) e.image_w;
					h := cast(float32) e.image_h;
					sc := min(1.0, min(max_w / w, 300 / h));
					embed_image("img", e, w * sc, h * sc, msg = m.id);
				} else if images {
					// the client's mosaic: 2 side by side, 3 as one tall left and two right, 4 in a 2x2
					spacer(.Y, 16);
					grid := row("grid");
					gw := min(400.0, max_w);
					gh := gw * 0.75;
					grid.semantic_size = .[ui.px(gw), ui.px(gh)];
					ui.parent(grid); defer ui.pop_parent();
					cw := (gw - 4) / 2;
					for col: 0..1 {
						if col spacer(.X, 4);
						c := ui.box(tprint("c%", col));
						c.semantic_size = .[ui.px(cw), ui.px(gh)];
						c.layout_axis = .Y;
						ui.parent(c); defer ui.pop_parent();
						// column 0: image 0 (and 2 of 4); column 1: image 1 (and 2 of 3, 3 of 4)
						second := ifx images.count == 4 then col + 2 else ifx images.count == 3 && col == 1 then 2 else -1;
						ch := ifx second >= 0 then (gh - 4) / 2 else gh;
						embed_image(tprint("g%", col), images[col], cw, ch, cover = true, msg = m.id);
						if second >= 0 {
							spacer(.Y, 4);
							embed_image(tprint("g%", second), images[second], cw, ch, cover = true, msg = m.id);
						}
					}
				}
				footer := e.footer;
				if e.timestamp_ms {
					when := format_time_ms(e.timestamp_ms);
					footer = ifx footer then tprint("% • %", footer, when) else when;
				}
				if footer {
					spacer(.Y, 8);
					fr := row("footrow");
					fr.semantic_size = .[ui.pct(1), ui.children()];
					fr.cross_align = .Center;
					ui.parent(fr); defer ui.pop_parent();
					if e.footer_icon { embed_icon("ficon", e.footer_icon, 20); spacer(.X, 8); }
					ft := ui.box("footer", .Wrap_Text);
					ft.semantic_size = .[ui.fill(), ui.text_size()];
					ft.style.line_height = 16;
					ui.set_spans(ft, ui.Span.[.{text = footer, font = F(.Medium), size = 12, color = T("--text-default")}]);
				}
				spacer(.Y, 16);
			}
			if e.thumbnail_url != "" && e.image_url == "" && e.thumbnail_w > 0 && !video && !poster {
				// fit in 80x80, keeping its shape (a film poster stays tall)
				spacer(.X, 16);
				tw, tht := cast(float32) e.thumbnail_w, cast(float32) max(e.thumbnail_h, 1);
				tsc := min(80 / tw, 80 / tht);
				th := ui.box("thumb", .Draw_Background);
				th.semantic_size = .[ui.px(tw * tsc), ui.px(tht * tsc)];
				th.style.radius = all4(4);
				set_remote_image(th, e.thumbnail_url);
			}
			spacer(.X, 16);
		}
		spacer(.Y, 4);
	}
}

// An embed's provider or author name: with a url, the hand and an underline on hover and a click follows it.
embed_link_text :: (id: string, text: string, url: string, weight: Font_Id, size: float32, color: ui.Color, m: *dc.Message) {
	t := ui.box(id, .Wrap_Text | .Selectable_Text);
	t.semantic_size = .[ui.fill(), ui.text_size()];
	t.style.line_height = size + 4;
	over := url != "" && ui.mouse_over(t) && ui.span_at(t.prev_layout, app.ui.mouse) >= 0 && !ui.overlay_at(app.ui.mouse);
	ui.set_spans(t, ui.Span.[.{text = text, font = F(weight), size = size, color = color, underline = over}]);
	if !over return;
	app.ui.span_cursor = .Pointer;
	for app.ui.events if it.kind == .Mouse_Up && it.button == .Left && !it.consumed && !ui.has_selection() && ui.span_at(t.prev_layout, it.pos) >= 0 follow_link(url, m.id);
}

// The author's (24) or footer's (20) round icon.
embed_icon :: (id: string, url: string, size: float32) {
	b := ui.box(id, .Draw_Background);
	b.semantic_size = .[ui.px(size), ui.px(size)];
	b.style.radius = all4(size / 2);
	set_remote_image(b, url);
}

// An embed's markdown (its description, a field's value): a box per block so quotes get their bar and
// links their clicks, since span ids are token indices within one block. sub orders selection.
embed_markdown :: (id: string, text: string, m: *dc.Message, sub: int) {
	for blk, bi: md_parse(text) {
		if bi > 0 spacer(.Y, 4);
		wrap := row(tprint("%blk%", id, bi));
		wrap.semantic_size = .[ui.pct(1), ui.children()];
		wrap.cross_align = .Start;
		ui.parent(wrap); defer ui.pop_parent();
		if blk.quoted {
			wrap.custom_draw = quote_bar_draw;
			spacer(.X, 12);
		}
		d := ui.box(id, .Wrap_Text | .Selectable_Text);
		d.semantic_size = .[ui.fill(), ui.text_size()];
		d.style.line_height = 18;
		d.style.text_color = T("--text-default");
		d.sel_order = cast(u64) m.id * 8 + 7;
		d.sel_sub = cast(u32) (sub + bi);
		if blk.kind == .Code_Block ui.set_spans(d, .[.{text = blk.code, font = F(.Mono), size = 12}]);
		else ui.set_spans(d, tokens_to_spans(blk.tokens, .Normal, 14, m));
		handle_span_clicks(d, blk.tokens, m.id);
	}
}

// An embed's image: opens the viewer, right-click for the media menu; cover crops it to fill w x h.
embed_image :: (id: string, e: *dc.Embed, w: float32, h: float32, cover := false, msg: dc.Snowflake = 0) {
	img := media_box(id, e.image_url, "", w, h);
	img.style.radius = all4(4);
	if cover set_remote_image(img, e.image_url, cover = true);
	sig := ui.signal(img);
	if sig.clicked open_viewer(e.image_url, .{e.image_w, e.image_h}, msg = msg);
	if sig.right_clicked media_menu_open(e.image_url, e.image_url);
}

// An embed's video player: the message id with the embed index, top bit set so it can't be an
// attachment id.
embed_player_key :: (m: *dc.Message, i: int) -> dc.Snowflake { return (m.id + cast(u64) i) | (1 << 63); }

// An image (animated ones play while drawn) or, with video, a GIFV: a muted looping video that plays only
// while on screen, its poster image until the first frame is in.
media_box :: (id: string, url: string, video: string, w: float32, h: float32) -> *ui.Box {
	b := ui.box(id, .Draw_Background | .Clickable | .Clip);
	b.semantic_size = .[ui.px(w), ui.px(h)];
	b.style.radius = all4(8);
	b.style.bg = T("--background-mod-subtle");
	if !video {
		set_remote_image(b, url);
		return b;
	}
	g := table_find_pointer(*gifvs, video);
	if !g {
		g = table_set(*gifvs, copy_string(video), .{});
		blob_get(video);
	}
	if ui.offscreen(b) return b;
	g.seen = app.frame;
	if !g.player {
		blob := table_find_pointer(*blobs, video);
		if blob && blob.state == .Ready {
			ensure_audio();
			g.player = media.player_open(media.source_from_memory(blob.data), autoplay = true, looping = true, muted = true);
		}
	}
	if g.player {
		if !media.player_is_playing(g.player) media.player_play(g.player);
		img := media.player_update(g.player);
		if img.y g.img = img;
		app.ui.animating = true;
	}
	if !g.img.y {
		set_remote_image(b, url);
	} else {
		d := New(Gifv_Draw,, temp);
		d.video = video;
		b.custom_draw = gifv_draw;
		b.custom_user = d;
	}
	return b;
}

// Start of a frame: GIFVs not drawn last frame stop, so nothing decodes offscreen and the app can sleep.
gifv_frame :: () {
	for * gifvs if it.player && it.seen + 1 < app.frame && media.player_is_playing(it.player) media.player_pause(it.player);
}

open_viewer :: (url: string, size: Int2, video := "", link := "", msg: dc.Snowflake = 0) {
	viewer_msg = msg;
	viewer_zoom, viewer_pan = 1, .{};
	free(viewer_url);
	free(viewer_video);
	free(viewer_link);
	viewer_url, viewer_video, viewer_link = copy_string(url), copy_string(video), copy_string(ifx link then link else url);
	viewer_size = size;
	viewer_t = 0;
}

media_overlays :: () {
	// A fullscreen video takes the screen (the OS's fullscreen), unless the window already was; leaving
	// either way leaves both.
	if platform.is_headless() {
	} else if fullscreen_video && !video_os_full && !platform.is_fullscreen() {
		platform.set_fullscreen(true);
		video_os_full, video_os_full_t = true, app.ui.time;
	} else if video_os_full && !fullscreen_video {
		platform.set_fullscreen(false);
		video_os_full = false;
	} else if video_os_full && !platform.is_fullscreen() && app.ui.time - video_os_full_t > 2 {
		fullscreen_video, video_os_full = 0, false; // the user left the OS's fullscreen (macOS animates in first)
	}
	if fullscreen_video video_fullscreen();
	if viewer_url != "" image_viewer();
	if mm.open media_menu();
}

Viewer_Item :: struct { url: string; size: Int2; video: string; link: string; }

// The images of a message the viewer steps through, in message order: image attachments (not hidden
// spoilers), bare image and GIFV embeds, and rich embeds' images, as their views open them (temp).
viewer_items :: (m: *dc.Message) -> []Viewer_Item {
	out: [..]Viewer_Item;
	out.allocator = temp;
	if !m return out;
	for * a: m.attachments {
		hidden := (is_spoiler(a) || media_redaction(m, a.flags) != .Show) && !table_find_pointer(*revealed_spoilers, a.id);
		if is_video(a) || is_audio(a) || a.width <= 0 || a.height <= 0 || hidden || media_redaction(m, a.flags) == .Block continue;
		array_add(*out, .{ifx a.proxy_url then a.proxy_url else a.url, .{a.width, a.height}, "", a.url});
	}
	if m.flags & 4 return out; // SUPPRESS_EMBEDS
	for * e, i: m.embeds {
		if media_redaction(m, e.flags) != .Show && (media_redaction(m, e.flags) == .Block || !table_find_pointer(*revealed_spoilers, cast(u64) m.id + cast(u64) i + 1)) continue;
		if e.kind == "gifv" || (e.kind == "image" && e.title == "") {
			url := ifx e.thumbnail_url != "" then e.thumbnail_url else e.image_url;
			w, h := max(e.thumbnail_w, e.image_w), max(e.thumbnail_h, e.image_h);
			if url != "" && w > 0 && h > 0 array_add(*out, .{url, .{cast(int) w, cast(int) h}, ifx e.kind == "gifv" then e.video_url else "", e.url});
		} else if e.image_url != "" && e.image_w > 0 && e.image_h > 0 {
			array_add(*out, .{e.image_url, .{e.image_w, e.image_h}, "", e.image_url});
		}
	}
	return out;
}

// Full-window image viewer: dark scrim, image fit to 80% of the window, click outside or Escape closes.
// A message with more images gets previous / next arrows (and the Left / Right keys) and a count.
image_viewer :: () {
	items := viewer_items(ifx viewer_msg then find_message(viewer_msg));
	cur := -1;
	for items if it.url == viewer_url && it.video == viewer_video { cur = it_index; break; }
	step := 0;
	ui.animate(*viewer_t, 1, 25);
	scrim := ui.box("viewer_scrim", .Draw_Background | .Clickable | .Floating_X | .Floating_Y | .Overlay);
	scrim.semantic_size = .[ui.px(app.ui.window.x), ui.px(app.ui.window.y)];
	scrim.style.bg = .{0, 0, 0, 0.85 * viewer_t};
	if ui.signal(scrim).clicked {
		close_viewer();
		return;
	}
	{ ui.parent(scrim); defer ui.pop_parent();
		w := cast(float32) max(viewer_size.x, 1);
		h := cast(float32) max(viewer_size.y, 1);
		sc := min(app.ui.window.x * 0.8 / w, app.ui.window.y * 0.8 / h);
		sc *= 0.95 + 0.05 * viewer_t;
		// zoom: the wheel at the mouse, a click toggles 2x there, a drag pans
		c := app.ui.window * 0.5;
		zoom_to :: (z: float32, at: Vector2) #expand {
			z = clamp(z, 1, 8);
			viewer_pan = ifx z <= 1 then Vector2.{} else at - c - (at - c - viewer_pan) * (z / viewer_zoom);
			viewer_zoom = z;
		}
		for * app.ui.events if it.kind == .Scroll && !it.consumed && !mm.open {
			zoom_to(viewer_zoom * exp(it.delta.y * 0.002), app.ui.mouse);
			it.consumed = true;
		}
		zw, zh := w * sc * viewer_zoom, h * sc * viewer_zoom;
		lim := Vector2.{max(0.0, (zw - app.ui.window.x) / 2 + 40), max(0.0, (zh - app.ui.window.y) / 2 + 40)};
		viewer_pan = .{clamp(viewer_pan.x, -lim.x, lim.x), clamp(viewer_pan.y, -lim.y, lim.y)};
		img := media_box("img", viewer_url, viewer_video, zw, zh);
		img.flags |= .Floating_X | .Floating_Y | .Click_On_Release;
		img.flags &= ~ui.Box_Flags.Draw_Background;
		img.style.radius = all4(0);
		img.fixed_pos = c + viewer_pan - Vector2.{zw, zh} * 0.5;
		img.opacity = viewer_t;
		isig := ui.signal(img);
		if isig.pressed viewer_pan0, viewer_moved = viewer_pan, false;
		if isig.dragging && viewer_zoom > 1 {
			if length(isig.drag_delta) > 3 viewer_moved = true;
			if viewer_moved viewer_pan = viewer_pan0 + isig.drag_delta;
		}
		if isig.clicked && !viewer_moved zoom_to(ifx viewer_zoom > 1 then 1.0 else 2.0, app.ui.mouse);
		if isig.right_clicked media_menu_open(viewer_link, ifx viewer_video then "" else viewer_url);
		// the client's link under the image
		ob := ui.box(L("Open in Browser##ob"), .Clickable | .Draw_Text | .Floating_X | .Floating_Y);
		ob.semantic_size = .[ui.text_size(0), ui.px(20)];
		ob.fixed_pos = .{(app.ui.window.x - w * sc) / 2, (app.ui.window.y + h * sc) / 2 + 8};
		ob.style.font = F(.Medium);
		ob.style.font_size = 14;
		obs := ui.signal(ob);
		ob.style.text_color = ifx obs.hovering then ui.Color.{1, 1, 1, 1} else .{1, 1, 1, 0.7};
		ob.hover_cursor = .Pointer;
		if obs.clicked open_url(viewer_link);
		if cur >= 0 && items.count > 1 {
			for dir: int.[-1, 1] {
				b := ui.box(ifx dir < 0 then "prev" else "next", .Clickable | .Draw_Background | .Floating_X | .Floating_Y | .Hot_Animation);
				b.semantic_size = .[ui.px(44), ui.px(44)];
				b.fixed_pos = .{ifx dir < 0 then 24.0 else app.ui.window.x - 68, (app.ui.window.y - 44) / 2};
				b.style.radius = all4(22);
				b.style.bg = .{0, 0, 0, 0.5};
				b.style.bg_hot = .{0, 0, 0, 0.75};
				b.layout_axis = .X;
				b.cross_align = .Center;
				if ui.signal(b).clicked step = dir;
				ui.parent(b); defer ui.pop_parent();
				spacer(.X, 10);
				icon("ic", ifx dir < 0 then "chevron-small-left" else "chevron-small-right", 24, .{1, 1, 1, 1});
			}
			n := row("count");
			n.flags |= .Floating_X | .Floating_Y;
			n.semantic_size = .[ui.children(), ui.px(20)];
			n.fixed_pos = .{app.ui.window.x / 2 - 20, app.ui.window.y - 40};
			ui.parent(n); defer ui.pop_parent();
			label(tprint("% / %", cur + 1, items.count), .Medium, 14, .{1, 1, 1, 0.8}, 20);
		}
	}
	if !mm.open for * app.ui.events {
		if it.kind != .Key_Down || it.consumed continue;
		if it.key == .Escape { close_viewer(); it.consumed = true; }
		if cur >= 0 && items.count > 1 && (it.key == .Left || it.key == .Right) { step = ifx it.key == .Left then -1 else 1; it.consumed = true; }
	}
	if step && viewer_url != "" {
		next := items[(cur + step + items.count) % items.count];
		open_viewer(next.url, next.size, next.video, next.link, viewer_msg);
		viewer_t = 1; // no zoom-in between images
	}
}

// ---- image / media context menu ----
// The client's native media items (chunks e921316e4ac02b0c "copy-image"/"save-image" and d5621fd9c10fcdb0
// "copy-native-link"/"open-native-link"): Copy Image for jpg/jpeg/jfif/png/webp/avif, Save Image for those
// plus gif/tiff/bmp (or no extension), both only for Discord-hosted media; then Copy/Open Link, named
// "Image Link" for cdn.discordapp.com images and "Media Link" for other image/gif/video URLs.

media_menu_open :: (link: string, image: string) {
	free(mm.link);
	free(mm.image);
	mm.link, mm.image = copy_string(link), copy_string(image);
	mm.pos = app.ui.mouse;
	mm.open = true;
}

// Copy Image / Save Image downloads: the bytes go to a decode worker that does the rest.
media_action_receive :: (r: *dc.Media_Result) -> bool {
	if r.tag != MEDIA_TAG_COPY && r.tag != MEDIA_TAG_SAVE return false;
	if r.status == 200 && r.data {
		decode_submit(.{kind = ifx r.tag == MEDIA_TAG_COPY then Decode_Kind.Copy_Image else .Save_Image, url = copy_string(r.url), data = r.data, path = save_path_take(r.url)});
		r.data = .[];
	} else if r.tag == MEDIA_TAG_SAVE {
		toast_show(L("Couldn't save the image."), false);
	}
	return true;
}

// A file attachment's download: asked where in the Save dialog under the attachment's own name, then
// streamed to disk by a worker (dc.run_stream) while its card shows the bytes so far.
File_Download :: struct {
	url, path: string; // heap
	size: int; // the attachment's: anything else is a cut-short download
	progress: *dc.Media_Progress; // heap, the worker's until the result
}

file_downloads: [..]File_Download;

file_download_find :: (url: string) -> *File_Download {
	for * file_downloads if it.url == url return it;
	return null;
}

file_download :: (a: *dc.Attachment) {
	if file_download_find(a.url) return;
	app.ext_actions += 1;
	dest := platform.save_file_dialog(ifx a.filename then a.filename else download_name(a.url));
	if !dest return;
	c := ifx app.client then media_client(a.url);
	if !c { toast_show(L("File saved."), true); free(dest); return; } // offline runs write nothing
	d := array_add(*file_downloads);
	d.* = .{url = copy_string(a.url), path = dest, size = a.size, progress = New(dc.Media_Progress)};
	dc.fetch_media(c, .{url = a.url, visible = true, tag = MEDIA_TAG_FILE, save_to = dest, progress = d.progress});
}

file_download_receive :: (r: *dc.Media_Result) -> bool {
	if r.tag != MEDIA_TAG_FILE return false;
	d := file_download_find(r.url);
	if !d return true;
	ok := r.status == 200 && (d.size <= 0 || d.progress.done == d.size);
	toast_show(ifx ok then L("File saved.") else L("Couldn't save the file."), ok);
	if !ok file_delete(d.path);
	free(d.url);
	free(d.path);
	free(d.progress);
	array_unordered_remove_by_index(*file_downloads, d - file_downloads.data);
	return true;
}

media_reset_for_test :: () {
	close_viewer();
	fullscreen_video = 0;
	mm.open = false;
}

#scope_file

MEDIA_TAG_COPY :: 0x6d65_6469_6101;
MEDIA_TAG_SAVE :: 0x6d65_6469_6102;
MEDIA_TAG_FILE :: 0x6d65_6469_6103;

Gifv :: struct {
	player: *media.Player;
	img: media.Video_Image;
	seen: u64; // app.frame it was last on screen
}

gifvs: Table(string, Gifv); // video URL ->

Gifv_Draw :: struct {
	video: string;
}

gifv_draw :: (b: *ui.Box, user: *void) {
	g := table_find_pointer(*gifvs, (cast(*Gifv_Draw) user).video);
	if !g || g.img.y == 0 return;
	gfx.video(cast,force(gfx.Rect) b.rect, g.img.y, g.img.cbcr, g.img.yuv, b.style.radius[0]);
}

Media_Menu :: struct {
	open: bool;
	pos: ui.Vec2;
	link: string; // Copy / Open Link
	image: string; // Copy / Save Image ("" for a video)
}

mm: Media_Menu;

media_menu :: () {
	if outside_pressed("mmenu_scrim") || escape_pressed() {
		mm.open = false;
		return;
	}
	ext := url_ext(mm.image);
	asset := is_discord_media(mm.image);
	can_copy := mm.image && asset && array_find(string.["jpg", "jpeg", "jfif", "png", "webp", "avif"], ext);
	can_save := mm.image && asset && (ext == "" || array_find(string.["jpg", "jpeg", "jfif", "png", "webp", "gif", "tiff", "bmp", "avif"], ext));
	lext := url_ext(mm.link);
	image_link := url_host(mm.link) == "cdn.discordapp.com" && array_find(string.["png", "jpg", "jpeg", "webp", "avif", "bmp", "svg"], lext);
	media_link := !image_link && array_find(string.["png", "jpg", "jpeg", "webp", "avif", "bmp", "svg", "gif", "mp4", "webm", "mov"], lext);
	what := ifx image_link then "Image Link" else ifx media_link then "Media Link" else "Link";
	W :: cast(float32) GM_MENU_W;
	h := 16 + GM_ROW_H * (2 + cast(float32) (cast(int) can_copy + cast(int) can_save)) + ifx can_copy || can_save then 9.0 else 0;
	pos := mm.pos;
	if pos.x + W > app.ui.window.x - 8 pos.x = app.ui.window.x - 8 - W;
	if pos.y + h > app.ui.window.y - 8 pos.y = app.ui.window.y - 8 - h;
	close := false;
	menu := menu_panel("mmenu", pos, W);
	{ ui.parent(menu); defer ui.pop_parent();
		spacer(.Y, 8);
		if can_copy && menu_item("copy-image", L("Copy Image"), lead = "image").clicked {
			media_action(MEDIA_TAG_COPY, mm.image);
			close = true;
		}
		if can_save && menu_item("save-image", L("Save Image"), lead = "image").clicked {
			media_action(MEDIA_TAG_SAVE, mm.image);
			close = true;
		}
		if can_copy || can_save menu_sep("s1");
		if menu_item("copy-native-link", tprint(L("Copy %"), what), lead = "link").clicked {
			clipboard_set(mm.link);
			close = true;
		}
		if menu_item("open-native-link", tprint(L("Open %"), what), .Icon, "link-external-small", lead = "window-launch").clicked {
			open_url(mm.link);
			close = true;
		}
		spacer(.Y, 8);
	}
	if close mm.open = false;
}

// The client's saveImage/copyImage URL: media.discordapp.net becomes cdn.discordapp.com, the size and format
// parameters go, and format=png is asked for when the path has no extension.
media_action :: (tag: u64, u: string) {
	q :=find_index_from_left(u, #char "?");
	path, query := u, "";
	if q >= 0 path, query = slice(u, 0, q), slice(u, q + 1, u.count - q - 1);
	if url_host(path) == "media.discordapp.net" path = replace(path, "//media.discordapp.net/", "//cdn.discordapp.com/",, temp);
	sb: String_Builder;
	sb.allocator = temp;
	append(*sb, path);
	sep := "?";
	for split(query, "&",, temp) {
		key := it;
		eq := find_index_from_left(key, #char "=");
		if eq >= 0 key.count = eq;
		if !it || array_find(string.["width", "height", "quality", "size", "format"], key) continue;
		print_to_builder(*sb, "%1%2", sep, it);
		sep = "&";
	}
	if url_ext(path) == "" print_to_builder(*sb, "%format=png", sep);
	url := builder_to_string(*sb,, temp);
	if tag == MEDIA_TAG_SAVE {
		// Asked first, as the client's Save dialog: nothing downloads when it's cancelled.
		app.ext_actions += 1;
		dest := platform.save_file_dialog(download_name(path));
		if !dest return;
		save_path_take(url);
		table_set(*save_paths, copy_string(url), dest);
	}
	c := ifx app.client then media_client(url);
	if c dc.fetch_media(c, .{url = url, kind = .Image, visible = true, tag = tag});
	else decode_submit(.{kind = ifx tag == MEDIA_TAG_COPY then Decode_Kind.Copy_Image else .Save_Image, url = copy_string(url), path = save_path_take(url)});
}

// The file name Save Image offers: the URL's last path segment.
download_name :: (url: string) -> string {
	name := url;
	q := find_index_from_left(name, #char "?");
	if q >= 0 name.count = q;
	advance(*name, find_index_from_right(name, #char "/") + 1);
	if !name return "image.png";
	return ifx find_index_from_left(name, #char ".") < 0 then tprint("%.png", name) else name; // media_action asks for format=png
}

// Where each pending Save Image download goes, by its URL (heap keys and values).
save_paths: Table(string, string);

save_path_take :: (url: string) -> string {
	k, v: string;
	for path, key: save_paths if key == url { k, v = key, path; break; }
	if !k return "";
	table_remove(*save_paths, k);
	free(k);
	return v;
}

url_host :: (u: string) -> string {
	i := find_index_from_left(u, "://");
	if i < 0 return "";
	h := slice(u, i + 3, u.count - i - 3);
	for h if it == #char "/" || it == #char "?" || it == #char ":" { h.count = it_index; break; }
	return h;
}

// Lower-case extension of the URL's last path segment ("" if none).
url_ext :: (u: string) -> string {
	p := u;
	q := find_index_from_left(p, #char "?");
	if q >= 0 p.count = q;
	advance(*p, find_index_from_right(p, #char "/") + 1);
	dot := find_index_from_right(p, #char ".");
	if dot < 0 return "";
	return to_lower_copy(slice(p, dot + 1, p.count - dot - 1),, temp);
}

is_discord_media :: (u: string) -> bool {
	h := url_host(u);
	return h == "cdn.discordapp.com" || h == "media.discordapp.net" || (begins_with(h, "images-ext-") && ends_with(h, ".discordapp.net"));
}

close_viewer :: () {
	free(viewer_url);
	free(viewer_video);
	free(viewer_link);
	viewer_url, viewer_video, viewer_link = "", "", "";
}

// The player starts on a streamed download at once, else once the download is in.
player_open_ready :: (ip: *Inline_Player) {
	if ip.player return;
	blob := table_find_pointer(*blobs, ip.url);
	if !blob || (!blob.stream && blob.state != .Ready) return;
	ensure_audio();
	src := ifx blob.stream then media.source_from_growing(blob.stream) else media.source_from_memory(blob.data);
	ip.player = media.player_open(src, autoplay = true, muted = video_muted);
	media.player_set_volume(ip.player, video_volume);
	if ip.voice media.player_set_rate(ip.player, voice_rate);
}

voice_rate: float64 = 1; // voice messages' playback speed (the card's 1x / 1.5x / 2x), for every one

video_draw :: (b: *ui.Box, user: *void) {
	ip := table_find_pointer(*players, cast(dc.Snowflake) cast(u64) user);
	if !ip || ip.img.y == 0 return;
	gfx.video(cast,force(gfx.Rect) b.rect, ip.img.y, ip.img.cbcr, ip.img.yuv, b.style.radius[0]);
}

fmt_clock :: (t: float64) -> string {
	s := cast(int) t;
	return tprint("%:%", s / 60, formatInt(s % 60, minimum_digits = 2));
}
