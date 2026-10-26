package app

import "core:strings"
import dc "fc:discord"
import "fc:gfx"
import "fc:imagefmt"
import "fc:ui"

Image_State :: enum u8 {
	Loading,
	Ready,
	Failed,
}

Remote_Image :: struct {
	state:    Image_State,
	tex:      gfx.Texture,
	size:     [2]int,
	frames:   []gfx.Texture, // animated images: one texture per frame
	durations: []int,
	total_ms: int,
	last_use: u64,
}

// url -> image. Requests go through the discord library so they look like the
// official client's <img> loads and hit its HTTP cache.
images: map[string]Remote_Image

image_get :: proc(url: string, visible := true) -> ^Remote_Image {
	if url == "" do return nil
	if im, ok := &images[url]; ok {
		im.last_use = app.frame
		return im
	}
	key := strings.clone(url)
	images[key] = Remote_Image{state = .Loading, last_use = app.frame}
	if app.client != nil {
		dc.fetch_media(app.client, {url = key, kind = .Image, visible = visible})
	} else if data, ok := offline_media(key); ok {
		images[key] = image_decode(data)
	} else {
		images[key] = Remote_Image{state = .Failed}
	}
	return &images[key]
}

// Called each frame with finished loads.
images_receive :: proc() {
	if app.client == nil do return
	for &r in dc.client_take_media(app.client) {
		defer dc.media_result_free(app.client, &r)
		if blob_receive(&r) {
			app.ui.animating = true
			continue
		}
		if sounds_receive(&r) do continue
		if twemoji_receive(r.url, r.status, r.data) do continue
		im, ok := &images[r.url]
		if !ok do continue
		if r.status != 200 || len(r.data) == 0 {
			im.state = .Failed
			continue
		}
		if strings.has_suffix(r.url, ".woff2") || strings.contains(r.content_type, "font") {
			continue
		}
		last := im.last_use
		im^ = image_decode(r.data)
		im.last_use = last
		app.ui.animating = true // repaint with the new texture
	}
}

// Current frame texture (animated images advance with time).
image_texture :: proc(im: ^Remote_Image) -> gfx.Texture {
	if im == nil || im.state != .Ready do return 0
	if len(im.frames) <= 1 || im.total_ms <= 0 do return im.tex
	t := int(app.ui.time * 1000) % im.total_ms
	for d, i in im.durations {
		if t < d do return im.frames[i]
		t -= d
	}
	return im.frames[0]
}

@(private = "file")
Image_Draw :: struct {
	url: string,
}

@(private = "file")
image_draw :: proc(b: ^ui.Box, user: rawptr) {
	d := (^Image_Draw)(user)
	im := image_get(d.url)
	tex := image_texture(im)
	if tex == 0 do return
	if len(im.frames) > 1 do app.ui.animating = true
	white := gfx.Color{1, 1, 1, b.opacity}
	gfx.push_rect({dst = gfx.Rect(b.rect), tex = tex, colors = {white, white, white, white}, radii = b.style.radius})
}

// Draw a remote image filling the box (rounded like the box). Background shows while loading.
set_remote_image :: proc(b: ^ui.Box, url: string) {
	if url == "" do return
	image_get(url)
	d := new(Image_Draw, context.temp_allocator)
	d.url = url
	b.custom_draw = image_draw
	b.custom_user = d
}

attachment_image_url :: proc(a: ^dc.Attachment, w, h: int) -> string {
	if a.proxy_url == "" do return a.url
	sc := max(gfx.scale(), 1)
	return dc.media_proxy_url(a.proxy_url, int(f32(w) * sc), int(f32(h) * sc))
}

avatar_url_for :: proc(uid: dc.Snowflake, size: f32) -> string {
	u := dc.user_get(store(), uid)
	px := int(size * max(gfx.scale(), 1))
	// the client requests sizes in its fixed set
	sz := 16
	for s in ([]int{16, 20, 22, 24, 28, 32, 40, 44, 48, 56, 60, 64, 80, 96, 100, 128, 160, 240, 256, 300, 320, 480, 512, 600, 640, 1024, 1280, 1536, 2048, 3072, 4096}) {
		sz = s
		if s >= px do break
	}
	if u == nil do return dc.default_avatar_url(uid, "0")
	if u.avatar == "" do return dc.default_avatar_url(uid, u.discriminator)
	return dc.avatar_url(uid, u.avatar, sz)
}

avatar_box :: proc(id: string, uid: dc.Snowflake, size: f32) -> ^ui.Box {
	b := ui.box(id, {.Draw_Background})
	b.semantic_size = {.X = ui.px(size), .Y = ui.px(size)}
	b.style.radius = size / 2
	b.style.bg = T("--background-mod-normal")
	set_remote_image(b, avatar_url_for(uid, size))
	return b
}

// Avatar with the status dot cut out of the bottom-right, ringed in the surface color.
avatar_with_status :: proc(id: string, uid: dc.Snowflake, size: f32, surface: ui.Color) -> ^ui.Box {
	b := avatar_box(id, uid, size)
	dot := size >= 40 ? f32(12) : f32(10)
	ring := size >= 40 ? f32(4) : f32(3)
	if ui.parent(b) {
		r := ui.box("ring", {.Draw_Background, .Floating_X, .Floating_Y})
		r.semantic_size = {.X = ui.px(dot + ring * 2), .Y = ui.px(dot + ring * 2)}
		r.fixed_pos = {size - dot - ring, size - dot - ring}
		r.style.bg = surface
		r.style.radius = (dot + ring * 2) / 2
		if ui.parent(r) {
			d := ui.box("dot", {.Floating_X, .Floating_Y})
			d.semantic_size = {.X = ui.px(dot), .Y = ui.px(dot)}
			d.fixed_pos = {ring, ring}
			st := user_status(uid)
			set_icon(d, status_icon(st), status_color(st))
		}
	}
	return b
}

status_icon :: proc(st: dc.Status) -> string {
	switch st {
	case .Online:
		return "status-online"
	case .Idle:
		return "status-idle"
	case .Dnd:
		return "status-dnd"
	case .Offline, .Invisible:
		return "status-offline"
	}
	return "status-offline"
}

// Reaction / picker emoji: custom emoji are images, unicode ones are text.
emoji_inline :: proc(id: string, e: dc.Emoji, size: f32) -> ^ui.Box {
	if e.id != 0 {
		b := ui.box(id)
		b.semantic_size = {.X = ui.px(size), .Y = ui.px(size)}
		set_remote_image(b, dc.custom_emoji_url(e.id, e.animated, 48))
		return b
	}
	return label(e.name, .Normal, size * 0.9, {1, 1, 1, 1}, size)
}

// Rich-text inline object hook: custom emoji spans carry their id in user.
draw_custom_emoji :: proc(sp: ui.Span, r: ui.Rect, opacity: f32) {
	if draw_unicode_emoji_span(sp, r, opacity) do return
	id := dc.Snowflake(uintptr(sp.user))
	if id == 0 do return
	im := image_get(dc.custom_emoji_url(id, false, 48))
	tex := image_texture(im)
	if tex == 0 do return
	c := gfx.Color{1, 1, 1, opacity}
	gfx.push_rect({dst = gfx.Rect(r), tex = tex, colors = {c, c, c, c}})
}

// Decode image bytes into textures (all frames for animations).
image_decode :: proc(data: []byte) -> Remote_Image {
	im := Remote_Image{state = .Failed, last_use = app.frame}
	img, err := imagefmt.decode(data, context.temp_allocator)
	if err != nil || len(img.frames) == 0 do return im
	im.size = {img.width, img.height}
	if len(img.frames) == 1 {
		im.tex = gfx.texture_from_rgba(img.width, img.height, img.frames[0].pixels)
	} else {
		im.frames = make([]gfx.Texture, len(img.frames))
		im.durations = make([]int, len(img.frames))
		for f, i in img.frames {
			im.frames[i] = gfx.texture_from_rgba(img.width, img.height, f.pixels)
			im.durations[i] = f.duration_ms
			im.total_ms += f.duration_ms
		}
		im.tex = im.frames[0]
	}
	im.state = .Ready
	return im
}
