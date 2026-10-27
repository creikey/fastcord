// Inline players for video/audio attachments, embeds, and the image viewer.

Blob :: struct {
	state: Image_State;
	data: []u8;
}

// Raw downloads (videos, audio) keyed by URL; they share the media fetch path with images.
blobs: Table(string, Blob);

Inline_Player :: struct {
	player: *media.Player;
	url: string;
	img: media.Video_Image;
}

players: Table(dc.Snowflake, Inline_Player); // attachment id -> player
viewer_url: string; // image viewer overlay
viewer_size: Int2;
viewer_t: float32;
audio_ready: bool;

blob_get :: (url: string) -> *Blob {
	{ b, ok := map_find_ptr(*blobs, url);
	if ok { return b; } }
	key := clone(url);
	at(*blobs, key).* = Blob.{state = .Loading};
	if app.client != null {
		dc.fetch_media(app.client, .{url = key, kind = .Fetch, visible = true});
	} else {
		at(*blobs, key).* = Blob.{state = .Failed};
	}
	return at(*blobs, key);
}

// Takes a finished media download that belongs to a blob. Returns false if it's not a blob.
blob_receive :: (r: *dc.Media_Result) -> bool {
	b, ok := map_find_ptr(*blobs, r.url);
	if !ok { return false; }
	if r.status == 200 && len(r.data) > 0 {
		b.data = r.data;
		r.data = .[]; // keep ownership
		b.state = .Ready;
	} else {
		b.state = .Failed;
	}
	return true;
}

is_video :: (a: *dc.Attachment) -> bool {return strings.has_prefix(a.content_type, "video/");}
is_audio :: (a: *dc.Attachment) -> bool {return strings.has_prefix(a.content_type, "audio/");}
#scope_file

Video_Draw :: struct {
	id: dc.Snowflake;
}

video_draw :: (b: *ui.Box, user: *void) {
	d := cast(*Video_Draw)(user);
	ip, ok := map_find_ptr(*players, d.id);
	if !ok || ip.img.y == 0 { return; }
	gfx.video(cast,force(gfx.Rect)(b.rect), ip.img.y, ip.img.cbcr, ip.img.yuv, b.style.radius[0]);
}
#scope_export

fmt_clock :: (t: float64) -> string {
	s := cast(int)(t);
	return fmt.tprintf("%d:%02d", s / 60, s % 60);
}

// Video attachment: poster until clicked, then plays inline with a control bar.
video_attachment :: (a: *dc.Attachment, w: float32, h: float32) {
	box := ui.box(fmt.tprintf("vid%d", cast(u64)(a.id)), .Draw_Background | .Clickable | .Clip);
	box.semantic_size = .[ui.px(w), ui.px(h)];
	box.style.radius = all4(8);
	box.style.bg = .{0, 0, 0, 1};
	sig := ui.signal(box);
	ip, playing := map_find_ptr(*players, a.id);
	if !playing {
		// poster frame from the media proxy (?format=webp of a video returns a still)
		set_remote_image(box, attachment_image_url(a, cast(int)(w), cast(int)(h)));
		if sig.clicked {
			blob := blob_get(a.url);
			at(*players, a.id).* = Inline_Player.{url = clone(a.url)};
		}
	} else {
		if ip.player == null {
			{ blob, ok := map_find_ptr(*blobs, ip.url);
			if ok && blob.state == .Ready {
				ensure_audio();
				ip.player = media.player_open(media.source_from_memory(blob.data), autoplay = true);
			} }
		}
		if ip.player != null {
			img, changed := media.player_update(ip.player);
			if img.y != 0 { ip.img = img; }
			if media.player_is_playing(ip.player) { app.ui.animating = true; }
			d := new(Video_Draw, temp);
			d.id = a.id;
			box.custom_draw = video_draw;
			box.custom_user = d;
			if sig.clicked { media.player_toggle(ip.player); }
		}
	}
	{ ui.parent(box); defer ui.pop_parent();
		hovered := sig.hovering;
		if !playing || (ip.player != null && !media.player_is_playing(ip.player)) {
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
		if playing && ip.player != null && hovered {
			bar := row("controls", .Draw_Background | .Floating_X | .Floating_Y);
			bar.semantic_size = .[ui.px(w), ui.px(32)];
			bar.fixed_pos = .{0, h - 32};
			bar.style.bg = .{0, 0, 0, 0.6};
			{ ui.parent(bar); defer ui.pop_parent();
				spacer(.X, 8);
				label(fmt.tprintf("%s / %s", fmt_clock(media.player_position(ip.player)), fmt_clock(media.player_duration(ip.player))), .Medium, 12, .{1, 1, 1, 1}, 16);
				spacer(.X, 8);
				dur := media.player_duration(ip.player);
				frac := ifx dur > 0 then cast(float32)(media.player_position(ip.player) / dur) else 0;
				track := ui.box("track", .Draw_Background | .Clickable);
				track.semantic_size = .[ui.fill(), ui.px(6)];
				track.style.bg = .{1, 1, 1, 0.3};
				track.style.radius = all4(3);
				tsig := ui.signal(track);
				if tsig.pressed || tsig.dragging {
					tw := track.rect.x1 - track.rect.x0;
					if tw > 0 { media.player_seek(ip.player, cast(float64)(clamp((app.ui.mouse.x - track.rect.x0) / tw, 0, 1)) * dur); }
				}
				{ ui.parent(track); defer ui.pop_parent();
					fill := ui.box("fill", .Draw_Background | .Floating_X | .Floating_Y);
					fill.semantic_size = .[ui.px((track.rect.x1 - track.rect.x0) * frac), ui.px(6)];
					fill.style.bg = T("--background-brand");
					fill.style.radius = all4(3);
				}
				spacer(.X, 12);
			}
		}
	}
}

ensure_audio :: () {
	if audio_ready { return; }
	audio_ready = audio.init();
	if !audio_ready {
		audio.init_null();
		audio_ready = true;
	}
}

// Audio attachment (and voice messages): file card with play button and progress.
audio_attachment :: (a: *dc.Attachment) {
	card := row(fmt.tprintf("aud%d", cast(u64)(a.id)), .Draw_Background | .Draw_Border);
	card.semantic_size = .[ui.px(400), ui.px(56)];
	card.style.bg = T("--background-surface-high");
	card.style.border_color = T("--border-subtle");
	card.style.border = 1;
	card.style.radius = all4(8);
	ip, playing := map_find_ptr(*players, a.id);
	if playing && ip.player == null {
		{ blob, ok := map_find_ptr(*blobs, ip.url);
		if ok && blob.state == .Ready {
			ensure_audio();
			ip.player = media.player_open(media.source_from_memory(blob.data), autoplay = true);
		} }
	}
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
				blob_get(a.url);
				at(*players, a.id).* = Inline_Player.{url = clone(a.url)};
			} else if ip.player != null {
				media.player_toggle(ip.player);
			}
		}
		spacer(.X, 12);
		col := ui.box("col");
		col.semantic_size = .[ui.fill(), ui.children()];
		{ ui.parent(col); defer ui.pop_parent();
			label(a.filename, .Medium, 14, T("--text-link"), 18);
			pos, dur: float64;
			if playing && ip.player != null {
				pos = media.player_position(ip.player);
				dur = media.player_duration(ip.player);
				if is_playing { app.ui.animating = true; }
			} else {
				dur = cast(float64)(a.duration_secs);
			}
			label(fmt.tprintf("%s / %s", fmt_clock(pos), fmt_clock(dur)), .Normal, 12, T("--text-muted"), 16);
		}
		spacer(.X, 12);
	}
}

// Link embeds: colored left bar, provider/author/title/description, image or thumbnail.
embeds_view :: (m: *dc.Message) {
	for * e, i: m.embeds {
		if e.kind == "gifv" || (e.kind == "image" && e.title == "") {
			// bare media links render as the media itself
			url := ifx e.thumbnail_url != "" then e.thumbnail_url else e.image_url;
			w := cast(float32)(max(e.thumbnail_w, e.image_w));
			h := cast(float32)(max(e.thumbnail_h, e.image_h));
			if url == "" || w <= 0 || h <= 0 { continue; }
			sc := min(1.0, min(400 / w, 300 / h));
			img := ui.box(fmt.tprintf("emedia%d", i), .Draw_Background | .Clickable);
			img.semantic_size = .[ui.px(w * sc), ui.px(h * sc)];
			img.style.radius = all4(8);
			img.style.bg = T("--background-mod-subtle");
			set_remote_image(img, url);
			if ui.signal(img).clicked { open_viewer(url, .{cast(int)(w), cast(int)(h)}); }
			spacer(.Y, 4);
			continue;
		}
		card := row(fmt.tprintf("embed%d", i), .Draw_Background);
		card.semantic_size = .[ui.px(432), ui.children()];
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
				if e.provider != "" { label(e.provider, .Normal, 12, T("--text-muted"), 16); }
				if e.author_name != "" {
					spacer(.Y, 4);
					label(e.author_name, .Semibold, 14, T("--text-strong"), 18);
				}
				if e.title != "" {
					spacer(.Y, 4);
					t := ui.box("title", .Wrap_Text | .Selectable_Text);
					t.semantic_size = .[ui.pct(1), ui.text_size()];
					t.style.line_height = 22;
					t.sel_order = cast(u64)(m.id) * 8 + 6;
					ui.set_spans(t, ui.Span.[.{text = e.title, font = F(.Semibold), size = 16, color = ifx e.url != "" then T("--text-link") else T("--text-strong")}]);
				}
				if e.description != "" {
					spacer(.Y, 8);
					d := ui.box("desc", .Wrap_Text | .Selectable_Text);
					d.semantic_size = .[ui.pct(1), ui.text_size()];
					d.style.line_height = 18;
					d.style.text_color = T("--text-default");
					d.sel_order = cast(u64)(m.id) * 8 + 7;
					blocks := md_parse(e.description);
					spans := make_dynamic(ui.Span, 0, 0, temp);
					for blk, bi: blocks {
						if bi > 0 { append(*spans, ui.Span.{text = "\n", font = F(.Normal), size = 14}); }
						append(*spans, ..tokens_to_spans(blk.tokens, .Normal, 14, m));
					}
					ui.set_spans(d, view(spans));
				}
				if e.image_url != "" && e.image_w > 0 {
					spacer(.Y, 16);
					w := cast(float32)(e.image_w);
					h := cast(float32)(e.image_h);
					sc := min(1.0, min(400 / w, 300 / h));
					img := ui.box("img", .Draw_Background | .Clickable);
					img.semantic_size = .[ui.px(w * sc), ui.px(h * sc)];
					img.style.radius = all4(4);
					img.style.bg = T("--background-mod-subtle");
					set_remote_image(img, e.image_url);
					if ui.signal(img).clicked { open_viewer(e.image_url, .{e.image_w, e.image_h}); }
				}
				spacer(.Y, 16);
			}
			if e.thumbnail_url != "" && e.image_url == "" && e.thumbnail_w > 0 {
				spacer(.X, 16);
				th := ui.box("thumb", .Draw_Background);
				th.semantic_size = .[ui.px(80), ui.px(80)];
				th.style.radius = all4(4);
				set_remote_image(th, e.thumbnail_url);
			}
			spacer(.X, 16);
		}
		spacer(.Y, 4);
	}
}

open_viewer :: (url: string, size: Int2) {
	delete(viewer_url);
	viewer_url = clone(url);
	viewer_size = size;
	viewer_t = 0;
}

// Full-window image viewer: dark scrim, image fit to 80% of the window, click outside or Escape closes.
image_viewer :: () {
	ui.animate(*viewer_t, 1, 25);
	scrim := ui.box("viewer_scrim", .Draw_Background | .Clickable | .Floating_X | .Floating_Y | .Overlay);
	scrim.semantic_size = .[ui.px(app.ui.window.x), ui.px(app.ui.window.y)];
	scrim.style.bg = .{0, 0, 0, 0.85 * viewer_t};
	if ui.signal(scrim).clicked {
		delete(viewer_url);
		viewer_url = "";
		return;
	}
	{ ui.parent(scrim); defer ui.pop_parent();
		w := cast(float32)(max(viewer_size.x, 1));
		h := cast(float32)(max(viewer_size.y, 1));
		sc := min(app.ui.window.x * 0.8 / w, app.ui.window.y * 0.8 / h);
		sc *= 0.95 + 0.05 * viewer_t;
		img := ui.box("img", .Floating_X | .Floating_Y | .Clickable);
		img.semantic_size = .[ui.px(w * sc), ui.px(h * sc)];
		img.fixed_pos = .{(app.ui.window.x - w * sc) / 2, (app.ui.window.y - h * sc) / 2};
		img.opacity = viewer_t;
		set_remote_image(img, viewer_url);
		ui.signal(img);
	}
	for e: app.ui.events {
		if e.kind == .Key_Down && e.key == .Escape {
			delete(viewer_url);
			viewer_url = "";
		}
	}
}

