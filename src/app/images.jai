Image_State :: enum u8 {
	Loading;
	Ready;
	Failed;
}

Remote_Image :: struct {
	state: Image_State;
	tex: gfx.Texture;
	size: Int2;
	frames: []gfx.Texture; // animated images: one texture per frame
	durations: []int;
	total_ms: int;
	last_use: u64;
	dominant: ui.Color; // most common opaque color of the first frame (profile banner fallback)
}

// url -> image. Requests go through the discord library so they look like the
// official client's <img> loads and hit its HTTP cache.
images: Table(string, Remote_Image);

image_get :: (url: string, visible := true) -> *Remote_Image {
	if url == "" return null;
	im := table_find_pointer(*images, url);
	if im {
		im.last_use = app.frame;
		return im;
	}
	key := copy_string(url);
	im = table_set(*images, key, .{state = .Loading, last_use = app.frame});
	if app.client != null {
		dc.fetch_media(app.client, .{url = key, kind = .Image, visible = visible});
	} else {
		data, ok := offline_media(key);
		im.* = ifx ok then image_decode(data) else .{state = .Failed};
	}
	return im;
}

// Called each frame with finished loads.
images_receive :: () {
	if app.client == null return;
	for * r: dc.client_take_media(app.client) {
		defer dc.media_result_free(app.client, r);
		if blob_receive(r) {
			app.ui.animating = true;
			continue;
		}
		if sounds_receive(r) continue;
		if twemoji_receive(r.url, r.status, r.data) continue;
		im := table_find_pointer(*images, r.url);
		if !im continue;
		if r.status != 200 || r.data.count == 0 {
			im.state = .Failed;
			continue;
		}
		if ends_with(r.url, ".woff2") || contains(r.content_type, "font") continue;
		last := im.last_use;
		im.* = image_decode(r.data);
		im.last_use = last;
		app.ui.animating = true; // repaint with the new texture
	}
}

// Current frame texture (animated images advance with time).
image_texture :: (im: *Remote_Image) -> gfx.Texture {
	if im == null || im.state != .Ready return 0;
	if im.frames.count <= 1 || im.total_ms <= 0 return im.tex;
	t := cast(int)(app.ui.time * 1000) % im.total_ms;
	for im.durations {
		if t < it return im.frames[it_index];
		t -= it;
	}
	return im.frames[0];
}

// Draw a remote image filling the box (rounded like the box). Background shows while loading.
set_remote_image :: (b: *ui.Box, url: string) {
	if url == "" return;
	image_get(url);
	d := New(Image_Draw,, temp);
	d.url = url;
	b.custom_draw = image_draw;
	b.custom_user = d;
}

attachment_image_url :: (a: *dc.Attachment, w: int, h: int) -> string {
	if a.proxy_url == "" return a.url;
	sc := max(gfx.scale(), 1);
	return dc.media_proxy_url(a.proxy_url, cast(int)(cast(float32)(w) * sc), cast(int)(cast(float32)(h) * sc));
}

avatar_url_for :: (uid: dc.Snowflake, size: float32) -> string {
	u := dc.user_get(store(), uid);
	px := cast(int)(size * max(gfx.scale(), 1));
	// the client requests sizes in its fixed set
	sz := 16;
	for s: (int.[16, 20, 22, 24, 28, 32, 40, 44, 48, 56, 60, 64, 80, 96, 100, 128, 160, 240, 256, 300, 320, 480, 512, 600, 640, 1024, 1280, 1536, 2048, 3072, 4096]) {
		sz = s;
		if s >= px break;
	}
	if u == null return dc.default_avatar_url(uid, "0");
	if u.avatar == "" return dc.default_avatar_url(uid, u.discriminator);
	return dc.avatar_url(uid, u.avatar, sz);
}

// Discord's default avatars: white Clyde on one of six colors, picked by
// (id >> 22) % 6 for pomelo users or discriminator % 5 for legacy ones.
DEFAULT_AVATAR_COLORS := u32.[0x5865f2, 0x757e8a, 0x3ba55c, 0xfaa61a, 0xed4245, 0xeb459f];
DEFAULT_AVATAR_GLYPH :: 0.65; // clyde icon box / avatar size (its glyph fills 22/24 of the box)

default_avatar_index :: (uid: dc.Snowflake) -> int {
	u := dc.user_get(store(), uid);
	if u != null && u.discriminator != "" && u.discriminator != "0" {
		d := 0;
		for c: cast([]u8) u.discriminator if c >= #char "0" && c <= #char "9" d = d * 10 + c - #char "0";
		return d % 5;
	}
	return cast(int)(((cast(u64)(uid)) >> 22) % 6);
}

avatar_box :: (id: string, uid: dc.Snowflake, size: float32) -> *ui.Box {
	b := ui.box(id, .Draw_Background);
	b.semantic_size = .[ui.px(size), ui.px(size)];
	b.style.radius = all4(size / 2);
	b.style.bg = T("--background-mod-normal");
	u := dc.user_get(store(), uid);
	d := New(Avatar_Draw,, temp);
	d.url = avatar_url_for(uid, size);
	d.default = -1;
	if u == null || u.avatar == "" {
		d.default = default_avatar_index(uid);
		b.style.bg = .{};
	}
	image_get(d.url);
	b.custom_draw = avatar_draw;
	b.custom_user = d;
	return b;
}

// Avatar with the status dot cut out of the bottom-right, ringed in the surface color.
avatar_with_status :: (id: string, uid: dc.Snowflake, size: float32, surface: ui.Color) -> *ui.Box {
	b := avatar_box(id, uid, size);
	dot := ifx size >= 80 then cast(float32)(16) else (ifx size >= 40 then cast(float32)(12) else cast(float32)(10)); // 80px profile avatars: 16px dot
	ring := ifx size >= 40 then cast(float32)(4) else cast(float32)(3);
	{ ui.parent(b); defer ui.pop_parent();
		r := ui.box("ring", .Draw_Background | .Floating_X | .Floating_Y);
		r.semantic_size = .[ui.px(dot + ring * 2), ui.px(dot + ring * 2)];
		r.fixed_pos = .{size - dot - ring, size - dot - ring};
		r.style.bg = surface;
		r.style.radius = all4((dot + ring * 2) / 2);
		{ ui.parent(r); defer ui.pop_parent();
			d := ui.box("dot", .Floating_X | .Floating_Y);
			d.semantic_size = .[ui.px(dot), ui.px(dot)];
			d.fixed_pos = .{ring, ring};
			st := user_status(uid);
			set_icon(d, status_icon(st), status_color(st));
		}
	}
	return b;
}

status_icon :: (st: dc.Status) -> string {
	if st == {
	case .Online;
		return "status-online";
	case .Idle;
		return "status-idle";
	case .Dnd;
		return "status-dnd";
	case .Offline; #through; case .Invisible;
		return "status-offline";
	}
	return "status-offline";
}

// Reaction / picker emoji: custom emoji are images, unicode ones are text.
emoji_inline :: (id: string, e: dc.Emoji, size: float32) -> *ui.Box {
	if e.id != 0 {
		b := ui.box(id);
		b.semantic_size = .[ui.px(size), ui.px(size)];
		set_remote_image(b, dc.custom_emoji_url(e.id, e.animated, 48));
		return b;
	}
	return label(e.name, .Normal, size * 0.9, .{1, 1, 1, 1}, size);
}

// Rich-text inline object hook: custom emoji spans carry their id in user.
draw_custom_emoji :: (sp: ui.Span, r: ui.Rect, opacity: float32) {
	if draw_unicode_emoji_span(sp, r, opacity) return;
	id := cast(dc.Snowflake)(cast(u64)(sp.user));
	if id == 0 return;
	im := image_get(dc.custom_emoji_url(id, false, 48));
	tex := image_texture(im);
	if tex == 0 return;
	c := gfx.Color.{1, 1, 1, opacity};
	gfx.push_rect(.{dst = cast,force(gfx.Rect)(emoji_square(r)), tex = tex, colors = .[c, c, c, c]});
}

// The client tints banner-less profiles with the avatar's dominant color: the
// most populated 4-bit-per-channel bucket among opaque pixels, averaged.
dominant_color :: (rgba: []u8) -> ui.Color {
	counts := NewArray(4096, u32,, temp);
	sums := NewArray(4096, [3]u32,, temp);
	step := max(1, rgba.count / 4 / 16384); // sample at most ~16k pixels
	i := 0;
	while i + 3 < rgba.count {
		defer i += 4 * step;
		if rgba[i + 3] < 128 continue;
		r, g, b := rgba[i], rgba[i + 1], rgba[i + 2];
		k := (((cast(int) r) >> 4) << 8) | (((cast(int) g) >> 4) << 4) | ((cast(int) b) >> 4);
		counts[k] += 1;
		sums[k][0] += r; sums[k][1] += g; sums[k][2] += b;
	}
	best := -1;
	for counts if it > 0 && (best < 0 || it > counts[best]) best = it_index;
	if best < 0 return .{};
	n := cast(float32) counts[best];
	return .{cast(float32)(sums[best][0]) / n / 255, cast(float32)(sums[best][1]) / n / 255, cast(float32)(sums[best][2]) / n / 255, 1};
}

// Decode image bytes into textures (all frames for animations).
image_decode :: (data: []u8) -> Remote_Image {
	im := Remote_Image.{state = .Failed, last_use = app.frame};
	img, err := imagefmt.decode(data, temp, 16 << 20);
	if err != .None || img.frames.count == 0 return im;
	im.size = .{img.width, img.height};
	im.dominant = dominant_color(img.frames[0].pixels);
	if img.frames.count == 1 {
		im.tex = gfx.texture_from_rgba(img.width, img.height, img.frames[0].pixels);
	} else {
		im.frames = NewArray(img.frames.count, gfx.Texture);
		im.durations = NewArray(img.frames.count, int);
		for img.frames {
			im.frames[it_index] = gfx.texture_from_rgba(img.width, img.height, it.pixels);
			im.durations[it_index] = it.duration_ms;
			im.total_ms += it.duration_ms;
		}
		im.tex = im.frames[0];
	}
	im.state = .Ready;
	return im;
}

#scope_file

Image_Draw :: struct {
	url: string;
}

image_draw :: (b: *ui.Box, user: *void) {
	d := cast(*Image_Draw)(user);
	im := image_get(d.url);
	tex := image_texture(im);
	if tex == 0 return;
	if im.frames.count > 1 app.ui.animating = true;
	white := gfx.Color.{1, 1, 1, b.opacity};
	gfx.push_rect(.{dst = cast,force(gfx.Rect)(b.rect), tex = tex, colors = .[white, white, white, white], radii = b.style.radius});
}

Avatar_Draw :: struct {
	url: string;
	default: int; // >= 0: draw the default avatar until (or instead of) the image
}

avatar_draw :: (b: *ui.Box, user: *void) {
	d := cast(*Avatar_Draw)(user);
	im := image_get(d.url);
	tex := image_texture(im);
	if tex != 0 {
		if im.frames.count > 1 app.ui.animating = true;
		white := gfx.Color.{1, 1, 1, b.opacity};
		gfx.push_rect(.{dst = cast,force(gfx.Rect)(b.rect), tex = tex, colors = .[white, white, white, white], radii = b.style.radius});
		return;
	}
	if d.default < 0 return;
	// Local rendering of the default avatar: identical to the CDN image, shown instantly and offline.
	c := cast(gfx.Color)(rgb_u32(DEFAULT_AVATAR_COLORS[d.default]));
	c.w = b.opacity;
	gfx.push_rect(.{dst = cast,force(gfx.Rect)(b.rect), colors = .[c, c, c, c], radii = b.style.radius});
	w := b.rect.x1 - b.rect.x0;
	h := b.rect.y1 - b.rect.y0;
	gw := w * DEFAULT_AVATAR_GLYPH; // official glyph spans 154/256 of the avatar width
	gx := b.rect.x0 + (w - gw) / 2;
	gy := b.rect.y0 + (h - gw) / 2;
	ic := icon_texture("clyde", gw);
	if ic == 0 return;
	wc := gfx.Color.{1, 1, 1, b.opacity};
	gfx.push_rect(.{dst = .{gx, gy, gx + gw, gy + gw}, tex = ic, colors = .[wc, wc, wc, wc]});
}
