package app

import "core:fmt"
import "core:strings"
import "fc:audio"
import dc "fc:discord"
import "fc:gfx"
import "fc:media"
import "fc:ui"

// Inline players for video/audio attachments, embeds, and the image viewer.

Blob :: struct {
	state: Image_State,
	data:  []byte,
}

// Raw downloads (videos, audio) keyed by URL; they share the media fetch path with images.
blobs: map[string]Blob

Inline_Player :: struct {
	player: ^media.Player,
	url:    string,
	img:    media.Video_Image,
}

players: map[dc.Snowflake]Inline_Player // attachment id -> player
viewer_url: string // image viewer overlay
viewer_size: [2]int
viewer_t: f32
audio_ready: bool

blob_get :: proc(url: string) -> ^Blob {
	if b, ok := &blobs[url]; ok do return b
	key := strings.clone(url)
	blobs[key] = Blob{state = .Loading}
	if app.client != nil {
		dc.fetch_media(app.client, {url = key, kind = .Fetch, visible = true})
	} else {
		blobs[key] = Blob{state = .Failed}
	}
	return &blobs[key]
}

// Takes a finished media download that belongs to a blob. Returns false if it's not a blob.
blob_receive :: proc(r: ^dc.Media_Result) -> bool {
	b, ok := &blobs[r.url]
	if !ok do return false
	if r.status == 200 && len(r.data) > 0 {
		b.data = r.data
		r.data = nil // keep ownership
		b.state = .Ready
	} else {
		b.state = .Failed
	}
	return true
}

is_video :: proc(a: ^dc.Attachment) -> bool {return strings.has_prefix(a.content_type, "video/")}
is_audio :: proc(a: ^dc.Attachment) -> bool {return strings.has_prefix(a.content_type, "audio/")}

@(private = "file")
Video_Draw :: struct {
	id: dc.Snowflake,
}

@(private = "file")
video_draw :: proc(b: ^ui.Box, user: rawptr) {
	d := (^Video_Draw)(user)
	ip, ok := &players[d.id]
	if !ok || ip.img.y == 0 do return
	gfx.video(gfx.Rect(b.rect), ip.img.y, ip.img.cbcr, ip.img.yuv, b.style.radius[0])
}

fmt_clock :: proc(t: f64) -> string {
	s := int(t)
	return fmt.tprintf("%d:%02d", s / 60, s % 60)
}

// Video attachment: poster until clicked, then plays inline with a control bar.
video_attachment :: proc(a: ^dc.Attachment, w, h: f32) {
	box := ui.box(fmt.tprintf("vid%d", u64(a.id)), {.Draw_Background, .Clickable, .Clip})
	box.semantic_size = {.X = ui.px(w), .Y = ui.px(h)}
	box.style.radius = 8
	box.style.bg = {0, 0, 0, 1}
	sig := ui.signal(box)
	ip, playing := &players[a.id]
	if !playing {
		// poster frame from the media proxy (?format=webp of a video returns a still)
		set_remote_image(box, attachment_image_url(a, int(w), int(h)))
		if sig.clicked {
			blob := blob_get(a.url)
			_ = blob
			players[a.id] = Inline_Player{url = strings.clone(a.url)}
		}
	} else {
		if ip.player == nil {
			if blob, ok := &blobs[ip.url]; ok && blob.state == .Ready {
				ensure_audio()
				ip.player = media.player_open(media.source_from_memory(blob.data), autoplay = true)
			}
		}
		if ip.player != nil {
			img, changed := media.player_update(ip.player)
			if img.y != 0 do ip.img = img
			_ = changed
			if media.player_is_playing(ip.player) do app.ui.animating = true
			d := new(Video_Draw, context.temp_allocator)
			d.id = a.id
			box.custom_draw = video_draw
			box.custom_user = d
			if sig.clicked do media.player_toggle(ip.player)
		}
	}
	if ui.parent(box) {
		hovered := sig.hovering
		if !playing || (ip.player != nil && !media.player_is_playing(ip.player)) {
			pb := ui.box("play", {.Draw_Background, .Floating_X, .Floating_Y})
			pb.semantic_size = {.X = ui.px(48), .Y = ui.px(48)}
			pb.fixed_pos = {(w - 48) / 2, (h - 48) / 2}
			pb.style.radius = 24
			pb.style.bg = {0, 0, 0, 0.6}
			if ui.parent(pb) {
				pi := ui.box("i", {.Floating_X, .Floating_Y})
				pi.semantic_size = {.X = ui.px(24), .Y = ui.px(24)}
				pi.fixed_pos = {13, 12}
				set_icon(pi, "play", {1, 1, 1, 1})
			}
		}
		if playing && ip.player != nil && hovered {
			bar := row("controls", {.Draw_Background, .Floating_X, .Floating_Y})
			bar.semantic_size = {.X = ui.px(w), .Y = ui.px(32)}
			bar.fixed_pos = {0, h - 32}
			bar.style.bg = {0, 0, 0, 0.6}
			if ui.parent(bar) {
				spacer(.X, 8)
				label(fmt.tprintf("%s / %s", fmt_clock(media.player_position(ip.player)), fmt_clock(media.player_duration(ip.player))), .Medium, 12, {1, 1, 1, 1}, 16)
				spacer(.X, 8)
				dur := media.player_duration(ip.player)
				frac := dur > 0 ? f32(media.player_position(ip.player) / dur) : 0
				track := ui.box("track", {.Draw_Background, .Clickable})
				track.semantic_size = {.X = ui.fill(), .Y = ui.px(6)}
				track.style.bg = {1, 1, 1, 0.3}
				track.style.radius = 3
				tsig := ui.signal(track)
				if tsig.pressed || tsig.dragging {
					tw := track.rect.x1 - track.rect.x0
					if tw > 0 do media.player_seek(ip.player, f64(clamp((app.ui.mouse.x - track.rect.x0) / tw, 0, 1)) * dur)
				}
				if ui.parent(track) {
					fill := ui.box("fill", {.Draw_Background, .Floating_X, .Floating_Y})
					fill.semantic_size = {.X = ui.px((track.rect.x1 - track.rect.x0) * frac), .Y = ui.px(6)}
					fill.style.bg = T("--background-brand")
					fill.style.radius = 3
				}
				spacer(.X, 12)
			}
		}
	}
}

ensure_audio :: proc() {
	if audio_ready do return
	audio_ready = audio.init()
	if !audio_ready {
		audio.init_null()
		audio_ready = true
	}
}

// Audio attachment (and voice messages): file card with play button and progress.
audio_attachment :: proc(a: ^dc.Attachment) {
	card := row(fmt.tprintf("aud%d", u64(a.id)), {.Draw_Background, .Draw_Border})
	card.semantic_size = {.X = ui.px(400), .Y = ui.px(56)}
	card.style.bg = T("--background-surface-high")
	card.style.border_color = T("--border-subtle")
	card.style.border = 1
	card.style.radius = 8
	ip, playing := &players[a.id]
	if playing && ip.player == nil {
		if blob, ok := &blobs[ip.url]; ok && blob.state == .Ready {
			ensure_audio()
			ip.player = media.player_open(media.source_from_memory(blob.data), autoplay = true)
		}
	}
	if ui.parent(card) {
		spacer(.X, 12)
		pb := ui.box("play", {.Clickable, .Draw_Background, .Hot_Animation})
		pb.semantic_size = {.X = ui.px(32), .Y = ui.px(32)}
		pb.style.radius = 16
		pb.style.bg = T("--background-brand")
		pb.style.bg_hot = with_alpha(T("--background-brand"), 0.85)
		is_playing := playing && ip.player != nil && media.player_is_playing(ip.player)
		if ui.parent(pb) {
			pi := ui.box("i", {.Floating_X, .Floating_Y})
			pi.semantic_size = {.X = ui.px(18), .Y = ui.px(18)}
			pi.fixed_pos = {7, 7}
			set_icon(pi, is_playing ? "pause" : "play", {1, 1, 1, 1})
		}
		if ui.signal(pb).clicked {
			if !playing {
				blob_get(a.url)
				players[a.id] = Inline_Player{url = strings.clone(a.url)}
			} else if ip.player != nil {
				media.player_toggle(ip.player)
			}
		}
		spacer(.X, 12)
		col := ui.box("col")
		col.semantic_size = {.X = ui.fill(), .Y = ui.children()}
		if ui.parent(col) {
			label(a.filename, .Medium, 14, T("--text-link"), 18)
			pos, dur: f64
			if playing && ip.player != nil {
				pos = media.player_position(ip.player)
				dur = media.player_duration(ip.player)
				if is_playing do app.ui.animating = true
			} else {
				dur = f64(a.duration_secs)
			}
			label(fmt.tprintf("%s / %s", fmt_clock(pos), fmt_clock(dur)), .Normal, 12, T("--text-muted"), 16)
		}
		spacer(.X, 12)
	}
}

// Link embeds: colored left bar, provider/author/title/description, image or thumbnail.
embeds_view :: proc(m: ^dc.Message) {
	for &e, i in m.embeds {
		if e.kind == "gifv" || (e.kind == "image" && e.title == "") {
			// bare media links render as the media itself
			url := e.thumbnail_url != "" ? e.thumbnail_url : e.image_url
			w := f32(max(e.thumbnail_w, e.image_w))
			h := f32(max(e.thumbnail_h, e.image_h))
			if url == "" || w <= 0 || h <= 0 do continue
			sc := min(1, min(400 / w, 300 / h))
			img := ui.box(fmt.tprintf("emedia%d", i), {.Draw_Background, .Clickable})
			img.semantic_size = {.X = ui.px(w * sc), .Y = ui.px(h * sc)}
			img.style.radius = 8
			img.style.bg = T("--background-mod-subtle")
			set_remote_image(img, url)
			if ui.signal(img).clicked do open_viewer(url, {int(w), int(h)})
			spacer(.Y, 4)
			continue
		}
		card := row(fmt.tprintf("embed%d", i), {.Draw_Background})
		card.semantic_size = {.X = ui.px(432), .Y = ui.children()}
		card.cross_align = .Start
		card.style.bg = T("--embed-background")
		card.style.radius = 4
		if ui.parent(card) {
			bar := ui.box("bar", {.Draw_Background, .Floating_X, .Floating_Y})
			bar.semantic_size = {.X = ui.px(4), .Y = ui.px(card.rect.y1 - card.rect.y0)}
			bar.style.radius = {4, 0, 4, 0}
			bar.style.bg = e.color != 0 ? rgb_u32(e.color) : T("--border-strong")
			spacer(.X, 16)
			col := ui.box("col")
			col.semantic_size = {.X = ui.fill(), .Y = ui.children()}
			col.layout_axis = .Y
			if ui.parent(col) {
				spacer(.Y, 8)
				if e.provider != "" do label(e.provider, .Normal, 12, T("--text-muted"), 16)
				if e.author_name != "" {
					spacer(.Y, 4)
					label(e.author_name, .Semibold, 14, T("--text-strong"), 18)
				}
				if e.title != "" {
					spacer(.Y, 4)
					t := ui.box("title", {.Wrap_Text, .Selectable_Text})
					t.semantic_size = {.X = ui.pct(1), .Y = ui.text_size()}
					t.style.line_height = 22
					t.sel_order = u64(m.id) * 8 + 6
					ui.set_spans(t, []ui.Span{{text = e.title, font = F(.Semibold), size = 16, color = e.url != "" ? T("--text-link") : T("--text-strong")}})
				}
				if e.description != "" {
					spacer(.Y, 8)
					d := ui.box("desc", {.Wrap_Text, .Selectable_Text})
					d.semantic_size = {.X = ui.pct(1), .Y = ui.text_size()}
					d.style.line_height = 18
					d.style.text_color = T("--text-default")
					d.sel_order = u64(m.id) * 8 + 7
					blocks := md_parse(e.description)
					spans := make([dynamic]ui.Span, context.temp_allocator)
					for blk, bi in blocks {
						if bi > 0 do append(&spans, ui.Span{text = "\n", font = F(.Normal), size = 14})
						append(&spans, ..tokens_to_spans(blk.tokens, .Normal, 14, m))
					}
					ui.set_spans(d, spans[:])
				}
				if e.image_url != "" && e.image_w > 0 {
					spacer(.Y, 16)
					w := f32(e.image_w)
					h := f32(e.image_h)
					sc := min(1, min(400 / w, 300 / h))
					img := ui.box("img", {.Draw_Background, .Clickable})
					img.semantic_size = {.X = ui.px(w * sc), .Y = ui.px(h * sc)}
					img.style.radius = 4
					img.style.bg = T("--background-mod-subtle")
					set_remote_image(img, e.image_url)
					if ui.signal(img).clicked do open_viewer(e.image_url, {e.image_w, e.image_h})
				}
				spacer(.Y, 16)
			}
			if e.thumbnail_url != "" && e.image_url == "" && e.thumbnail_w > 0 {
				spacer(.X, 16)
				th := ui.box("thumb", {.Draw_Background})
				th.semantic_size = {.X = ui.px(80), .Y = ui.px(80)}
				th.style.radius = 4
				set_remote_image(th, e.thumbnail_url)
			}
			spacer(.X, 16)
		}
		spacer(.Y, 4)
	}
}

open_viewer :: proc(url: string, size: [2]int) {
	delete(viewer_url)
	viewer_url = strings.clone(url)
	viewer_size = size
	viewer_t = 0
}

// Full-window image viewer: dark scrim, image fit to 80% of the window, click outside or Escape closes.
image_viewer :: proc() {
	ui.animate(&viewer_t, 1, 25)
	scrim := ui.box("viewer_scrim", {.Draw_Background, .Clickable, .Floating_X, .Floating_Y, .Overlay})
	scrim.semantic_size = {.X = ui.px(app.ui.window.x), .Y = ui.px(app.ui.window.y)}
	scrim.style.bg = {0, 0, 0, 0.85 * viewer_t}
	if ui.signal(scrim).clicked {
		delete(viewer_url)
		viewer_url = ""
		return
	}
	if ui.parent(scrim) {
		w := f32(max(viewer_size.x, 1))
		h := f32(max(viewer_size.y, 1))
		sc := min(app.ui.window.x * 0.8 / w, app.ui.window.y * 0.8 / h)
		sc *= 0.95 + 0.05 * viewer_t
		img := ui.box("img", {.Floating_X, .Floating_Y, .Clickable})
		img.semantic_size = {.X = ui.px(w * sc), .Y = ui.px(h * sc)}
		img.fixed_pos = {(app.ui.window.x - w * sc) / 2, (app.ui.window.y - h * sc) / 2}
		img.opacity = viewer_t
		set_remote_image(img, viewer_url)
		ui.signal(img)
	}
	for e in app.ui.events {
		if e.kind == .Key_Down && e.key == .Escape {
			delete(viewer_url)
			viewer_url = ""
		}
	}
}
