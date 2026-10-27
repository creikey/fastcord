// Message stickers, rendered like the official client: 160x160 under the
// message body. PNG/APNG/GIF come from the media proxy (the client's
// getStickerAssetUrl: size = 160 * min(2, devicePixelRatio) snapped to its
// size list, .webp + quality=lossless for PNG, .png for APNG, .gif for GIF);
// Lottie (format 3) JSON from discord.com/stickers/<id>.json via the picker's
// Lottie renderer (pickers_lottie.odin). Lottie stickers animate only while
// drawn (on screen) and the window is focused; otherwise the first frame shows.

STICKER_PX :: 160;
#scope_file

MEDIA_SIZES := int.[16, 20, 22, 24, 28, 32, 40, 44, 48, 56, 60, 64, 80, 96, 100, 128, 160, 240, 256, 300, 320, 480, 512, 600, 640, 1024, 1280, 1536, 2048, 3072, 4096];

// The client's media-proxy size snapping.
best_media_size :: (px: int) -> int {
	for s: MEDIA_SIZES { if s >= px { return s; } }
	return MEDIA_SIZES[len(MEDIA_SIZES) - 1];
}
#scope_export

message_sticker_url :: (id: dc.Snowflake, format_type: int, css_size := STICKER_PX) -> string {
	if format_type == 3 { return dc.sticker_url(id, 3); }
	dpr := min(2, max(gfx.scale(), 1));
	size := best_media_size(cast(int)(cast(float32)(css_size) * dpr));
	ext := "webp";
	extra := "&quality=lossless";
	if format_type == {
	case 2;
		ext, extra = "png", "";
	case 4;
		ext, extra = "gif", "";
	}
	return fmt.tprintf("https://media.discordapp.net/stickers/%v.%s?size=%d%s", cast(u64)(id), ext, size, extra);
}

// Stickers attached to a message (Message.sticker_ids, metadata from sticker_items).
message_stickers_view :: (m: *dc.Message) {
	if len(m.sticker_ids) == 0 { return; }
	s := store();
	for id, i: m.sticker_ids {
		it_, ok := dc.sticker_item(s, id);
		format := ifx ok then it_.format_type else 1;
		b := ui.box(fmt.tprintf("sticker%d", i));
		b.semantic_size = .[ui.px(STICKER_PX), ui.px(STICKER_PX)];
		if format == 3 {
			if app.client == null { offline_lottie(id); }
			lottie_sticker_draw(b, id, app.focused);
		} else {
			url := message_sticker_url(id, format);
			image_get(url);
			d := new(Sticker_Draw, temp);
			d.url = url;
			b.custom_draw = sticker_image_draw;
			b.custom_user = d;
		}
		spacer(.Y, 4);
	}
}
#scope_file

Sticker_Draw :: struct {
	url: string;
}

// Like set_remote_image, but animated stickers hold their first frame while
// the window is unfocused.
sticker_image_draw :: (b: *ui.Box, user: *void) {
	d := cast(*Sticker_Draw)(user);
	im := image_get(d.url);
	if im == null || im.state != .Ready { return; }
	tex := im.tex;
	if app.focused {
		tex = image_texture(im);
		if len(im.frames) > 1 { app.ui.animating = true; }
	}
	if tex == 0 { return; }
	// fit the image's aspect into the box (stickers are square but be safe)
	r := b.rect;
	w, h := cast(float32)(im.size.x), cast(float32)(im.size.y);
	if w > 0 && h > 0 {
		bw, bh := r.x1 - r.x0, r.y1 - r.y0;
		sc := min(bw / w, bh / h);
		dx, dy := (bw - w * sc) / 2, (bh - h * sc) / 2;
		r = .{r.x0 + dx, r.y0 + dy, r.x0 + dx + w * sc, r.y0 + dy + h * sc};
	}
	c := gfx.Color.{1, 1, 1, b.opacity};
	gfx.push_rect(.{dst = cast(gfx.Rect)(r), tex = tex, colors = .{c, c, c, c}});
}

// Offline (fixture) runs: load the Lottie JSON from FASTCORD_MEDIA_DIR into the
// picker's sticker cache before it tries (and fails) to fetch it.
offline_lottie :: (id: dc.Snowflake) {
	if has(lottie_stickers, id) { return; }
	data, ok := offline_media(dc.sticker_url(id, 3));
	if !ok { return; }
	anim, err := lottie.load(data);
	if err != .None { return; }
	at(*lottie_stickers, id).* = Lottie_Sticker.{state = .Ready, anim = anim, frame = -1};
}
#scope_export

