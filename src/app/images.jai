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
	// offline: a worker reads FASTCORD_MEDIA_DIR (no data)
	if app.client != null dc.fetch_media(app.client, .{url = key, kind = .Image, visible = visible});
	else decode_submit(.{kind = .Image, url = copy_string(key)});
	return im;
}

// Called each frame: finished loads go to the decode workers, decoded images become textures.
images_receive :: () {
	if app.client != null for * r: dc.client_take_media(app.client) {
		defer dc.media_result_free(app.client, r);
		if media_action_receive(r) continue;
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
		// the worker owns the bytes now (same heap allocator as the client's)
		decode_submit(.{kind = .Image, url = copy_string(r.url), data = r.data});
		r.data = .[];
	}
	decode_upload();
	gifv_frame();
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
	pw, ph := cast(int)(cast(float32)(w) * sc), cast(int)(cast(float32)(h) * sc);
	// The client's getSrcWithWidthAndHeight asks no format for an animated source: the proxy then sends
	// the GIF itself (format=webp would be its first frame).
	if a.content_type == "image/gif" return tprint("%1%2width=%3&height=%4", a.proxy_url, dc.proxy_sep(a.proxy_url), pw, ph);
	return dc.media_proxy_url(a.proxy_url, pw, ph);
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
	gfx.push_rect(.{dst = cast,force(gfx.Rect)(r), tex = tex, colors = .[c, c, c, c]});
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

// ---- decoding off the UI thread ----
// Image bytes and Lottie stickers are decoded by DECODE_THREADS workers into premultiplied pixels, newest
// request first (what just scrolled into view). The UI thread only creates the textures, at most
// UPLOAD_BUDGET bytes of them per frame, so scrolling through a grid of GIFs never stalls a frame.

DECODE_THREADS :: 3;
UPLOAD_BUDGET :: 4 << 20;

Decode_Kind :: enum u8 {
	Image;
	Lottie_Load;
	Lottie_Still; // first frame of a loaded animation at px x px
	Fetch; // offline: a blob's bytes from FASTCORD_MEDIA_DIR
	Copy_Image; // the media menu's actions, with the downloaded bytes
	Save_Image;
}

Decode_Job :: struct {
	kind: Decode_Kind;
	url: string; // heap, owned: the images key / the media URL (offline reads)
	data: []u8; // heap, owned; empty: read the URL from FASTCORD_MEDIA_DIR
	id: dc.Snowflake; // Lottie
	px: int;
	anim: *lottie.Animation; // Lottie_Still; read-only while shared
}

Decoded :: struct {
	using job: Decode_Job;
	ok: bool;
	size: Int2;
	frames: [][]u8; // premultiplied RGBA, heap
	durations: []int;
	dominant: ui.Color;
	tex: []gfx.Texture; // uploaded so far (UI thread)
	next: int;
}

decode_submit :: (j: Decode_Job) {
	if !dec.threads[0] for * dec.threads it.* = dc.spawn(it_index, decode_worker);
	locks.lock(*dec.mu);
	array_add(*dec.jobs, j);
	locks.unlock(*dec.mu);
	locks.cond_signal(*dec.cv);
}

// Scripted runs: wait for the workers before each frame, so what a frame shows doesn't depend on timing.
decode_settle :: () {
	while true {
		locks.lock(*dec.mu);
		idle := dec.jobs.count == 0 && dec.busy == 0;
		locks.unlock(*dec.mu);
		if idle return;
		sleep_milliseconds(1);
	}
}

#scope_file

Decoder :: struct {
	mu: locks.Mutex;
	cv: locks.Cond;
	jobs: [..]Decode_Job;
	done: [..]Decoded;
	busy: int;
	threads: [DECODE_THREADS]*Thread;
	uploading: [..]Decoded; // UI thread
}

dec: Decoder;

decode_worker :: (_: int) {
	while true {
		locks.lock(*dec.mu);
		while !dec.jobs locks.cond_wait_with_timeout(*dec.cv, *dec.mu, 1000);
		j := pop(*dec.jobs);
		dec.busy += 1;
		locks.unlock(*dec.mu);
		d := decode_run(j);
		locks.lock(*dec.mu);
		array_add(*dec.done, d);
		dec.busy -= 1;
		locks.unlock(*dec.mu);
		reset_temporary_storage();
		platform.request_frame();
	}
}

decode_run :: (j: Decode_Job) -> Decoded {
	d := Decoded.{job = j};
	data := j.data;
	if !data data = offline_media(j.url);
	if j.kind == {
	case .Image;
		img, err := imagefmt.decode(data, max_pixels = 16 << 20);
		if err == .Too_Large img, err = imagefmt.decode_first_frame(data, max_pixels = 16 << 20); // a still beats nothing
		if err == .None && img.frames {
			d.size = .{img.width, img.height};
			d.dominant = dominant_color(img.frames[0].pixels);
			d.frames = NewArray(img.frames.count, []u8);
			d.durations = NewArray(img.frames.count, int);
			for img.frames {
				gfx.premultiply_in_place(it.pixels);
				d.frames[it_index] = it.pixels;
				d.durations[it_index] = it.duration_ms;
			}
			array_free(img.frames);
		}
	case .Lottie_Load;
		d.anim = lottie.load(data);
	case .Lottie_Still;
		p: lottie.Player;
		lottie.player_init(*p, j.anim, j.px, j.px);
		d.frames = NewArray(1, []u8);
		d.frames[0] = array_copy(lottie.render(*p, j.anim.ip));
		gfx.premultiply_in_place(d.frames[0]);
		d.size = .{j.px, j.px};
		lottie.player_destroy(*p);
	case .Fetch;
		if !j.data d.data = array_copy(data);
	case .Copy_Image;
		if data platform.clipboard_set_image(data);
	case .Save_Image;
		if data save_download(j.url, data);
	}
	if j.kind != .Fetch {
		array_free(d.data);
		d.data = .[];
	}
	d.ok = d.frames.count > 0 || d.anim != null || d.data.count > 0;
	return d;
}

// Save Image: ~/Downloads/<name from the URL>, " (n)" before the extension when taken (worker thread).
save_download :: (url: string, data: []u8) {
	name := url;
	q := find_index_from_left(name, #char "?");
	if q >= 0 name.count = q;
	advance(*name, find_index_from_right(name, #char "/") + 1);
	if !name name = "image.png";
	dot := find_index_from_right(name, #char ".");
	stem, ext := name, "";
	if dot > 0 stem, ext = slice(name, 0, dot), slice(name, dot, name.count - dot);
	path := tprint("%/Downloads/%", env_var("HOME"), name);
	for 1..999 {
		if !file_exists(path) break;
		path = tprint("%/Downloads/% (%)%", env_var("HOME"), stem, it, ext);
	}
	write_entire_file(path, data.data, data.count);
}

decode_free :: (d: *Decoded) {
	array_free(d.data);
	for d.frames array_free(it);
	array_free(d.frames);
	array_free(d.durations);
	array_free(d.tex);
	free(d.url);
}

// Textures for finished decodes, within the frame's upload budget; the rest waits for the next frame.
decode_upload :: () {
	locks.lock(*dec.mu);
	array_add(*dec.uploading, ..dec.done);
	dec.done.count = 0;
	locks.unlock(*dec.mu);
	budget := UPLOAD_BUDGET;
	i := 0;
	while i < dec.uploading.count {
		d := *dec.uploading[i];
		if budget <= 0 && d.ok && (d.kind == .Image || d.kind == .Lottie_Still) {
			app.ui.animating = true; // next frame
			break;
		}
		app.ui.animating = true; // repaint with the new texture
		im: *Remote_Image;
		if d.kind == .Image im = table_find_pointer(*images, d.url);
		if d.kind == .Fetch {
			blob_decoded(d.url, d.data);
			d.data = .[];
		} else if d.kind == .Lottie_Load || d.kind == .Lottie_Still {
			budget -= d.size.x * d.size.y * 4;
			lottie_decoded(d);
		} else if im && !d.ok {
			im.state = .Failed;
		} else if im {
			if !d.tex d.tex = NewArray(d.frames.count, gfx.Texture);
			while d.next < d.frames.count && budget > 0 {
				d.tex[d.next] = gfx.texture_create(d.size.x, d.size.y, .RGBA8, d.frames[d.next], premultiplied_alpha = true);
				array_free(d.frames[d.next]);
				d.frames[d.next] = .[];
				budget -= d.size.x * d.size.y * 4;
				d.next += 1;
			}
			// the first frame shows as soon as it is in; the animation starts once every frame is
			im.state, im.tex, im.size, im.dominant = Image_State.Ready, d.tex[0], d.size, d.dominant;
			if d.next < d.frames.count break;
			if d.tex.count > 1 {
				im.frames, im.durations = d.tex, d.durations;
				for d.durations im.total_ms += it;
				d.tex, d.durations = .[], .[];
			}
		}
		decode_free(d);
		array_unordered_remove_by_index(*dec.uploading, i);
	}
}

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
