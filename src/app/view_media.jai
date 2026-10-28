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
	poster: string;
	size: Vector2; // inline size: the fullscreen view's aspect
	img: media.Video_Image;
}

players: Table(dc.Snowflake, Inline_Player); // attachment id or embed_player_key -> player
viewer_url: string; // image viewer overlay (the poster for a GIFV)
viewer_video: string; // GIFV: the looping video
viewer_link: string; // the media menu's target
viewer_size: Int2;
viewer_t: float32;
audio_ready: bool;
video_volume: float32 = 1;
video_muted: bool;
fullscreen_video: dc.Snowflake; // the player shown fullscreen, 0 if none

blob_get :: (url: string) -> *Blob {
	b := table_find_pointer(*blobs, url);
	if b return b;
	key := copy_string(url);
	b = find_or_add(*blobs, key);
	b.state = .Loading;
	// offline: a decode worker reads FASTCORD_MEDIA_DIR
	if app.client dc.fetch_media(app.client, .{url = key, kind = .Fetch, visible = true});
	else decode_submit(.{kind = .Fetch, url = copy_string(key)});
	return b;
}

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
	if r.status == 200 && r.data {
		b.data = r.data;
		r.data = .[]; // keep ownership
		b.state = .Ready;
	} else {
		b.state = .Failed;
	}
	return true;
}

// Message attachments: videos, audio, images (GIFs animate), other files as cards; max_w narrows them
// (search results).
attachments_view :: (m: *dc.Message, max_w: float32 = 400) {
	for * a, i: m.attachments {
		if is_video(a) && a.width > 0 && a.height > 0 {
			w := cast(float32) a.width;
			h := cast(float32) a.height;
			sc := min(1.0, min(max_w / w, 300 / h));
			// poster frame from the media proxy (?format=webp of a video returns a still)
			video_player(a.id, a.url, attachment_image_url(a, cast(int) (w * sc), cast(int) (h * sc)), w * sc, h * sc, cast(float64) a.duration_secs);
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
			sig := ui.signal(img);
			if sig.clicked open_viewer(ifx a.proxy_url then a.proxy_url else a.url, .{a.width, a.height}, link = a.url);
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
		} else {
			f := row(tprint("file%", i), .Draw_Background | .Draw_Border);
			f.semantic_size = .[ui.px(min(432.0, max_w + 32)), ui.px(72)];
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
					label(human_size(a.size), .Normal, 12, T("--text-muted"), 16);
				}
				dl := ui.box("dl", .Clickable);
				dl.semantic_size = .[ui.px(32), ui.px(32)];
				dl.hover_cursor = .Pointer;
				sig := ui.signal(dl);
				{ ui.parent(dl); defer ui.pop_parent();
					ic := icon("i", "download", 24, T(ifx sig.hovering then "--interactive-icon-hover" else "--interactive-icon-default"), .Floating_X | .Floating_Y);
					ic.fixed_pos = .{4, 4};
				}
				if sig.hovering tooltip_below("Download", dl.rect);
				if sig.clicked || download media_save(a.url);
				spacer(.X, 12);
			}
			spacer(.Y, 4);
		}
	}
}

is_video ::(a: *dc.Attachment) -> bool { return begins_with(a.content_type, "video/"); }
is_audio :: (a: *dc.Attachment) -> bool { return begins_with(a.content_type, "audio/"); }

// Video attachment or embed video: poster with a play button and the control bar (play, time, seek,
// volume, fullscreen) until clicked, then plays inline; the bar hides while it plays unhovered. key names
// its player (an attachment id, or embed_player_key); full draws it in the fullscreen overlay.
video_player :: (key: dc.Snowflake, url: string, poster: string, w: float32, h: float32, duration: float64 = 0, full := false) -> *ui.Box {
	box := ui.box(tprint("vid%", cast(u64) key), .Draw_Background | .Clickable | .Clip);
	box.semantic_size = .[ui.px(w), ui.px(h)];
	box.style.radius = all4(ifx full then 0.0 else 8.0);
	box.style.bg = .{0, 0, 0, 1};
	sig := ui.signal(box);
	ip := table_find_pointer(*players, key);
	start :: () #expand {
		if `ip return;
		blob_get(url);
		`ip = table_set(*players, key, .{url = copy_string(url), poster = copy_string(poster), size = .{w, h}});
	}
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
				v := slider("vs", ifx video_muted then 0 else video_volume, ui.px(64));
				if v >= 0 video_volume_set(v, v == 0);
				spacer(.X, 4);
			}
			if video_button("mute", ifx video_muted || video_volume == 0 then "speaker-slash" else "voice-normal") video_volume_set(ifx video_volume == 0 then 1 else video_volume, !video_muted);
		}
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
	for app.ui.events if it.kind == .Key_Down && it.key == .Escape fullscreen_video = 0;
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
	ip := table_find_pointer(*players, a.id);
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
				blob_get(a.url);
				table_set(*players, a.id, .{url = copy_string(a.url)});
			} else if ip.player {
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
				if is_playing app.ui.animating = true;
			} else {
				dur = cast(float64) a.duration_secs;
			}
			label(tprint("% / %", fmt_clock(pos), fmt_clock(dur)), .Normal, 12, T("--text-muted"), 16);
		}
		spacer(.X, 12);
	}
}

// Link embeds: colored left bar, provider/author/title/description, image or thumbnail.
embeds_view :: (m: *dc.Message, max_w: float32 = 400) {
	for * e, i: m.embeds {
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
			if sig.clicked open_viewer(url, .{cast(int) w, cast(int) h}, video, e.url);
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
				if e.provider label(e.provider, .Normal, 12, T("--text-muted"), 16);
				if e.author_name != "" {
					spacer(.Y, 4);
					label(e.author_name, .Semibold, 14, T("--text-strong"), 18);
				}
				if e.title != "" {
					spacer(.Y, 4);
					t := ui.box("title", .Wrap_Text | .Selectable_Text);
					t.semantic_size = .[ui.pct(1), ui.text_size()];
					t.style.line_height = 22;
					t.sel_order = cast(u64) m.id * 8 + 6;
					ui.set_spans(t, ui.Span.[.{text = e.title, font = F(.Semibold), size = 16, color = ifx e.url != "" then T("--text-link") else T("--text-strong")}]);
				}
				if e.description != "" {
					spacer(.Y, 8);
					// a box per block so quotes get their bar and links their clicks (span ids are
					// token indices within one block)
					for blk, bi: md_parse(e.description) {
						if bi > 0 spacer(.Y, 4);
						wrap := row(tprint("dblk%", bi));
						wrap.semantic_size = .[ui.pct(1), ui.children()];
						wrap.cross_align = .Start;
						{ ui.parent(wrap); defer ui.pop_parent();
							if blk.kind == .Quote {
								wrap.custom_draw = quote_bar_draw;
								spacer(.X, 12);
							}
							d := ui.box("d", .Wrap_Text | .Selectable_Text);
							d.semantic_size = .[ui.fill(), ui.text_size()];
							d.style.line_height = 18;
							d.style.text_color = T("--text-default");
							d.sel_order = cast(u64) m.id * 8 + 7;
							if blk.kind == .Code_Block ui.set_spans(d, .[.{text = blk.code, font = F(.Mono), size = 12}]);
							else ui.set_spans(d, tokens_to_spans(blk.tokens, .Normal, 14, m));
							handle_span_clicks(d, blk.tokens, m.id);
						}
					}
				}
				if video {
					// a proxied video (FxTwitter, Reddit…) plays in the card; YouTube's iframe url doesn't
					spacer(.Y, 16);
					w := cast(float32) ifx e.video_w > 0 then e.video_w else e.thumbnail_w;
					h := cast(float32) ifx e.video_h > 0 then e.video_h else e.thumbnail_h;
					sc := min(1.0, min(400 / w, 300 / h));
					video_player(embed_player_key(m, i), e.video_url, e.thumbnail_url, w * sc, h * sc);
				} else if poster {
					spacer(.Y, 16);
					w := cast(float32) e.thumbnail_w;
					h := cast(float32) e.thumbnail_h;
					sc := min(400 / w, 300 / h);
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
					sig := ui.signal(th);
					if sig.clicked open_url(e.url);
					if sig.right_clicked media_menu_open(e.url, "");
				} else if images.count == 1 {
					spacer(.Y, 16);
					w := cast(float32) e.image_w;
					h := cast(float32) e.image_h;
					sc := min(1.0, min(400 / w, 300 / h));
					embed_image("img", e, w * sc, h * sc);
				} else if images {
					// the client's mosaic: 2 side by side, 3 as one tall left and two right, 4 in a 2x2
					spacer(.Y, 16);
					grid := row("grid");
					grid.semantic_size = .[ui.px(400), ui.px(300)];
					ui.parent(grid); defer ui.pop_parent();
					cw := 198.0;
					for col: 0..1 {
						if col spacer(.X, 4);
						c := ui.box(tprint("c%", col));
						c.semantic_size = .[ui.px(cw), ui.px(300)];
						c.layout_axis = .Y;
						ui.parent(c); defer ui.pop_parent();
						// column 0: image 0 (and 2 of 4); column 1: image 1 (and 2 of 3, 3 of 4)
						second := ifx images.count == 4 then col + 2 else ifx images.count == 3 && col == 1 then 2 else -1;
						ch := ifx second >= 0 then 148.0 else 300.0;
						embed_image(tprint("g%", col), images[col], cw, ch, cover = true);
						if second >= 0 {
							spacer(.Y, 4);
							embed_image(tprint("g%", second), images[second], cw, ch, cover = true);
						}
					}
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

// An embed's image: opens the viewer, right-click for the media menu; cover crops it to fill w x h.
embed_image :: (id: string, e: *dc.Embed, w: float32, h: float32, cover := false) {
	img := media_box(id, e.image_url, "", w, h);
	img.style.radius = all4(4);
	if cover set_remote_image(img, e.image_url, cover = true);
	sig := ui.signal(img);
	if sig.clicked open_viewer(e.image_url, .{e.image_w, e.image_h});
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

open_viewer :: (url: string, size: Int2, video := "", link := "") {
	free(viewer_url);
	free(viewer_video);
	free(viewer_link);
	viewer_url, viewer_video, viewer_link = copy_string(url), copy_string(video), copy_string(ifx link then link else url);
	viewer_size = size;
	viewer_t = 0;
}

media_overlays :: () {
	if fullscreen_video video_fullscreen();
	if viewer_url != "" image_viewer();
	if mm.open media_menu();
}

// Full-window image viewer: dark scrim, image fit to 80% of the window, click outside or Escape closes.
image_viewer :: () {
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
		img := media_box("img", viewer_url, viewer_video, w * sc, h * sc);
		img.flags |= .Floating_X | .Floating_Y;
		img.flags &= ~ui.Box_Flags.Draw_Background;
		img.style.radius = all4(0);
		img.fixed_pos = .{(app.ui.window.x - w * sc) / 2, (app.ui.window.y - h * sc) / 2};
		img.opacity = viewer_t;
		if ui.signal(img).right_clicked media_menu_open(viewer_link, ifx viewer_video then "" else viewer_url);
	}
	if !mm.open for app.ui.events if it.kind == .Key_Down && it.key == .Escape close_viewer();
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
		decode_submit(.{kind = ifx r.tag == MEDIA_TAG_COPY then Decode_Kind.Copy_Image else .Save_Image, url = copy_string(r.url), data = r.data});
		r.data = .[];
	}
	return true;
}

media_save :: (url: string) { media_action(MEDIA_TAG_SAVE, url); }

media_reset_for_test :: () {
	close_viewer();
	fullscreen_video = 0;
	mm.open = false;
}

#scope_file

MEDIA_TAG_COPY :: 0x6d65_6469_6101;
MEDIA_TAG_SAVE :: 0x6d65_6469_6102;

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
		if can_copy && menu_item("copy-image", "Copy Image", lead = "image").clicked {
			media_action(MEDIA_TAG_COPY, mm.image);
			close = true;
		}
		if can_save && menu_item("save-image", "Save Image", lead = "image").clicked {
			media_action(MEDIA_TAG_SAVE, mm.image);
			close = true;
		}
		if can_copy || can_save menu_sep("s1");
		if menu_item("copy-native-link", tprint("Copy %", what), lead = "link").clicked {
			clipboard_set(mm.link);
			close = true;
		}
		if menu_item("open-native-link", tprint("Open %", what), .Icon, "link-external-small", lead = "window-launch").clicked {
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
	if app.client dc.fetch_media(app.client, .{url = url, kind = .Image, visible = true, tag = tag});
	else decode_submit(.{kind = ifx tag == MEDIA_TAG_COPY then Decode_Kind.Copy_Image else .Save_Image, url = copy_string(url)});
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

// The player starts once its download is in.
player_open_ready :: (ip: *Inline_Player) {
	if ip.player return;
	blob := table_find_pointer(*blobs, ip.url);
	if !blob || blob.state != .Ready return;
	ensure_audio();
	ip.player = media.player_open(media.source_from_memory(blob.data), autoplay = true, muted = video_muted);
	media.player_set_volume(ip.player, video_volume);
}

video_draw :: (b: *ui.Box, user: *void) {
	ip := table_find_pointer(*players, cast(dc.Snowflake) cast(u64) user);
	if !ip || ip.img.y == 0 return;
	gfx.video(cast,force(gfx.Rect) b.rect, ip.img.y, ip.img.cbcr, ip.img.yuv, b.style.radius[0]);
}

fmt_clock :: (t: float64) -> string {
	s := cast(int) t;
	return tprint("%:%", s / 60, formatInt(s % 60, minimum_digits = 2));
}
