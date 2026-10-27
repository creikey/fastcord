// Message stickers, rendered like the official client: 160x160 under the
// message body. PNG/APNG/GIF come from the media proxy (the client's
// getStickerAssetUrl: size = 160 * min(2, devicePixelRatio) snapped to its
// size list, .webp + quality=lossless for PNG, .png for APNG, .gif for GIF);
// Lottie (format 3) JSON from discord.com/stickers/<id>.json via the picker's
// Lottie renderer (pickers_lottie.jai). Lottie stickers animate only while
// drawn (on screen) and the window is focused; otherwise the first frame shows.

STICKER_PX :: 160;

message_sticker_url :: (id: dc.Snowflake, format_type: int, css_size := STICKER_PX) -> string {
	if format_type == 3 return dc.sticker_url(id, 3);
	dpr := min(2.0, max(gfx.scale(), 1));
	size := best_media_size(cast(int) (cast(float32) css_size * dpr));
	ext, extra := "webp", "&quality=lossless";
	if format_type == 2 { ext, extra = "png", ""; }
	if format_type == 4 { ext, extra = "gif", ""; }
	return tprint("https://media.discordapp.net/stickers/%1.%2?size=%3%4", id, ext, size, extra);
}

// Stickers attached to a message (Message.sticker_ids, metadata from sticker_items).
message_stickers_view :: (m: *dc.Message) {
	s := store();
	for id: m.sticker_ids {
		item, ok := dc.sticker_item(s, id);
		format := ifx ok then item.format_type else 1;
		b := ui.box(tprint("sticker%", it_index));
		b.semantic_size = .[ui.px(STICKER_PX), ui.px(STICKER_PX)];
		if format == 3 {
			lottie_sticker_draw(b, id, app.focused);
		} else {
			url := message_sticker_url(id, format);
			image_get(url);
			d := New(Sticker_Draw,, temp);
			d.url = url;
			b.custom_draw = sticker_image_draw;
			b.custom_user = d;
		}
		spacer(.Y, 4);
	}
}

#scope_file

MEDIA_SIZES :: int.[16, 20, 22, 24, 28, 32, 40, 44, 48, 56, 60, 64, 80, 96, 100, 128, 160, 240, 256, 300, 320, 480, 512, 600, 640, 1024, 1280, 1536, 2048, 3072, 4096];

// The client's media-proxy size snapping.
best_media_size :: (px: int) -> int {
	for MEDIA_SIZES if it >= px return it;
	return MEDIA_SIZES[MEDIA_SIZES.count - 1];
}

Sticker_Draw :: struct {
	url: string;
}

// Like set_remote_image, but animated stickers hold their first frame while
// the window is unfocused.
sticker_image_draw :: (b: *ui.Box, user: *void) {
	d := cast(*Sticker_Draw) user;
	im := image_get(d.url);
	if im == null || im.state != .Ready return;
	tex := im.tex;
	if app.focused {
		tex = image_texture(im);
		if im.frames.count > 1 app.ui.animating = true;
	}
	if tex == 0 return;
	// fit the image's aspect into the box (stickers are square but be safe)
	r := b.rect;
	w, h := cast(float32) im.size.x, cast(float32) im.size.y;
	if w > 0 && h > 0 {
		bw, bh := r.x1 - r.x0, r.y1 - r.y0;
		sc := min(bw / w, bh / h);
		dx, dy := (bw - w * sc) / 2, (bh - h * sc) / 2;
		r = .{r.x0 + dx, r.y0 + dy, r.x0 + dx + w * sc, r.y0 + dy + h * sc};
	}
	c := gfx.Color.{1, 1, 1, b.opacity};
	gfx.push_rect(.{dst = cast,force(gfx.Rect) r, tex = tex, colors = .[c, c, c, c]});
}
