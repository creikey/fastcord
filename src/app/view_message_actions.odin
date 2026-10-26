package app

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import dc "fc:discord"
import "fc:ui"

Message_Actions :: struct {
	replying:      dc.Snowflake, // message being replied to (composer bar)
	reply_mention: bool, // "@ ON" toggle
	editing:       dc.Snowflake, // message in inline edit mode
	edit_editor:   ui.Editor,
	deleting:      dc.Snowflake, // delete confirmation modal
	menu_msg:      dc.Snowflake, // context menu target
	menu_pos:      ui.Vec2,
	menu_t:        f32,
	uploads:       [dynamic]Pending_Upload, // files attached to the next message
}

Pending_Upload :: struct {
	path:     string,
	filename: string,
	data:     []byte,
	mime:     string,
}

ma: Message_Actions

mime_for :: proc(name: string) -> string {
	switch strings.to_lower(filepath.ext(name), context.temp_allocator) {
	case ".png":
		return "image/png"
	case ".jpg", ".jpeg":
		return "image/jpeg"
	case ".gif":
		return "image/gif"
	case ".webp":
		return "image/webp"
	case ".mp4":
		return "video/mp4"
	case ".mov":
		return "video/quicktime"
	case ".webm":
		return "video/webm"
	case ".mp3":
		return "audio/mpeg"
	case ".ogg":
		return "audio/ogg"
	case ".wav":
		return "audio/wav"
	case ".txt":
		return "text/plain"
	}
	return "application/octet-stream"
}

// A file dropped on the window (or chosen in the upload dialog) is staged for the next message.
stage_upload :: proc(path: string) {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil do return
	name := filepath.base(path)
	append(&ma.uploads, Pending_Upload{path = strings.clone(path), filename = strings.clone(name), data = data, mime = mime_for(name)})
}

uploads_clear :: proc() {
	for u in ma.uploads {
		delete(u.path)
		delete(u.filename)
		delete(u.data)
	}
	clear(&ma.uploads)
}

// Hover toolbar at the message's top-right: react, reply, (edit), more.
message_toolbar :: proc(m: ^dc.Message) {
	s := store()
	own := m.author_id == s.me
	quick := quick_reactions()
	names := own ? []string{"reaction", "pencil", "more-horizontal"} : []string{"reaction", "arrow-angle-left-up", "more-horizontal"}
	// official: 3px padding, 28px buttons, a 1px divider with 4px gaps after the quick reactions
	w := 2 * TOOLBAR_PAD + f32(len(quick) + len(names)) * TOOLBAR_BTN + (len(quick) > 0 ? 9 : 0)
	bar := row("toolbar", {.Draw_Background, .Draw_Border, .Draw_Shadow, .Floating_X, .Floating_Y, .Clickable})
	bar.semantic_size = {.X = ui.px(w), .Y = ui.px(TOOLBAR_BTN + 2 * TOOLBAR_PAD)}
	bar.fixed_pos = {ui.top_parent().rect.x1 - ui.top_parent().rect.x0 - w - 14, -16}
	bar.style.bg = T("--background-surface-higher")
	bar.style.border_color = T("--border-subtle")
	bar.style.border = 1
	bar.style.radius = 8
	bar.style.shadow_color = {0, 0, 0, 0.16}
	bar.style.shadow_blur = 4
	ui.signal(bar)
	if ui.parent(bar) {
		spacer(.X, TOOLBAR_PAD)
		for e, i in quick {
			b := ui.box(fmt.tprintf("q%d", i), {.Clickable, .Draw_Background, .Hot_Animation})
			b.semantic_size = {.X = ui.px(TOOLBAR_BTN), .Y = ui.px(TOOLBAR_BTN)}
			b.style.radius = 6
			b.style.bg_hot = T("--background-mod-subtle")
			b.layout_axis = .X
			b.cross_align = .Center
			if ui.signal(b).clicked && net_action() do dc.add_reaction(app.client, m.channel_id, m.id, e.name, e.id)
			if ui.parent(b) {
				spacer(.X, 4)
				emoji_box("e", e, 20)
			}
		}
		if len(quick) > 0 {
			spacer(.X, 4)
			d := ui.box("div", {.Draw_Background})
			d.semantic_size = {.X = ui.px(1), .Y = ui.px(24)}
			d.style.bg = T("--border-subtle")
			spacer(.X, 4)
		}
		for name in names {
			b := ui.box(name, {.Clickable, .Draw_Background, .Hot_Animation})
			b.semantic_size = {.X = ui.px(TOOLBAR_BTN), .Y = ui.px(TOOLBAR_BTN)}
			b.style.radius = 6
			b.style.bg_hot = T("--background-mod-subtle")
			b.layout_axis = .X
			b.cross_align = .Center
			sig := ui.signal(b)
			if ui.parent(b) {
				spacer(.X, 4)
				icon("i", name, 20, sig.hovering ? T("--interactive-icon-hover") : T("--interactive-icon-default"))
			}
			if sig.clicked {
				switch name {
				case "arrow-angle-left-up":
					start_reply(m)
				case "pencil":
					start_edit(m)
				case "more-horizontal":
					open_message_menu(m, {b.rect.x0, b.rect.y1 + 4})
				case "reaction":
					app.reaction_target = m.id
				}
			}
		}
	}
}

TOOLBAR_PAD :: 3
TOOLBAR_BTN :: 28

// The three most-used reactions (frecency), topped up with the client's defaults.
quick_reactions :: proc() -> []dc.Emoji {
	out := make([dynamic]dc.Emoji, 0, 3, context.temp_allocator)
	add :: proc(out: ^[dynamic]dc.Emoji, key: string) {
		if len(out) >= 3 do return
		e: dc.Emoji
		if id, ok := strconv.parse_u64(key); ok {
			found := false
			for _, &g in store().guilds {
				for ge in g.emojis do if u64(ge.id) == id {e, found = ge, true}
			}
			if !found do return
		} else {
			idx := emoji_lookup_name(key)
			if idx < 0 do return
			e.name = emoji_db.emojis[idx].surr
		}
		for x in out do if x.id == e.id && x.name == e.name do return
		append(out, e)
	}
	for k in frec_top(frecency.reaction, 3) do add(&out, k)
	for k in emoji_db.default_reaction do add(&out, k)
	return out[:]
}

start_reply :: proc(m: ^dc.Message) {
	ma.replying = m.id
	ma.reply_mention = true
	app.ui.focus = 0
}

start_edit :: proc(m: ^dc.Message) {
	ma.editing = m.id
	ui.editor_set_text(&ma.edit_editor, m.content)
}

open_message_menu :: proc(m: ^dc.Message, at: ui.Vec2) {
	ma.menu_msg = m.id
	ma.menu_pos = at
	ma.menu_t = 0
}

find_message :: proc(id: dc.Snowflake) -> ^dc.Message {
	if id == 0 do return nil
	s := store()
	l, ok := &s.messages[app.view.channel]
	if !ok do return nil
	for &m in l.messages do if m.id == id do return &m
	return nil
}

// Inline editor replacing the message body. Enter saves, Escape cancels.
edit_box :: proc(m: ^dc.Message) {
	// official: same form as the composer (58px, 1px border), emoji button on the right
	box := row("editbox", {.Draw_Background, .Draw_Border, .Clickable})
	box.semantic_size = {.X = ui.pct(1), .Y = ui.children()}
	box.style.bg = T("--chat-background-default")
	box.style.border_color = T("--border-subtle")
	box.style.border = 1
	box.style.radius = 8
	box.cross_align = .Start
	if ui.parent(box) {
		spacer(.X, 16)
		res := text_field("edit", &ma.edit_editor, "", true, pad_y = (COMPOSER_H - MSG_LINE_H) / 2)
		emo := ui.box("emoji", {.Clickable})
		emo.semantic_size = {.X = ui.px(20), .Y = ui.px(COMPOSER_H)}
		emo.layout_axis = .Y
		if ui.parent(emo) {
			spacer(.Y, (COMPOSER_H - 20) / 2)
			icon("i", "reaction", 20, T("--interactive-icon-default"))
		}
		spacer(.X, 10)
		switch res {
		case .Submit:
			text := strings.trim_space(ui.editor_text(&ma.edit_editor))
			if text == "" {
				ma.deleting = m.id
			} else if text != m.content && net_action() {
				dc.edit_message(app.client, m.channel_id, m.id, text)
			}
			ma.editing = 0
		case .Escape:
			ma.editing = 0
		case .None, .Changed, .Moved:
		}
	}
	hint := row("edithint")
	hint.semantic_size = {.X = ui.pct(1), .Y = ui.px(22)}
	if ui.parent(hint) {
		// one rich-text run so the spaces between the parts survive
		h := ui.box("hint")
		h.semantic_size = {.X = ui.text_size(0, 0), .Y = ui.text_size()}
		h.style.line_height = 16
		h.style.text_color = T("--text-default")
		spans := make([]ui.Span, 4, context.temp_allocator)
		spans[0] = {text = "escape to ", font = F(.Normal), size = 12}
		spans[1] = {text = "cancel", font = F(.Normal), size = 12, color = T("--text-link")}
		spans[2] = {text = " • enter to ", font = F(.Normal), size = 12}
		spans[3] = {text = "save", font = F(.Normal), size = 12, color = T("--text-link")}
		ui.set_spans(h, spans)
	}
}

// The referenced message preview above a reply: curved spine, small avatar, name, one line of content.
reply_preview :: proc(m: ^dc.Message) {
	s := store()
	ref := find_message(m.referenced_id)
	r := row("replyref")
	r.semantic_size = {.X = ui.pct(1), .Y = ui.px(22)}
	if ui.parent(r) {
		// the spine: only the top and left edges of a rounded box (clipped)
		clip := ui.box("spineclip", {.Clip, .Floating_X, .Floating_Y})
		clip.semantic_size = {.X = ui.px(33), .Y = ui.px(12)}
		clip.fixed_pos = {-MSG_GUTTER + 36, 8}
		if ui.parent(clip) {
			spine := ui.box("spine", {.Draw_Border, .Floating_X, .Floating_Y})
			spine.semantic_size = {.X = ui.px(33 + 8), .Y = ui.px(12 + 8)}
			spine.style.border = 2
			spine.style.border_color = T("--border-strong")
			spine.style.radius = {6, 0, 0, 0}
		}
		if ref == nil {
			label("Original message was deleted", .Normal, 14, T("--text-muted"), 18)
			return
		}
		avatar_box("av", ref.author_id, 16)
		spacer(.X, 4)
		name := "Unknown"
		if u := dc.user_get(s, ref.author_id); u != nil do name = dc.display_name(u)
		// "@" only when the reply pinged the author; role color, else muted
		pinged := false
		for id in m.mentions do if id == ref.author_id do pinged = true
		name_color := T("--text-muted")
		if ch := dc.channel_get(s, ref.channel_id); ch != nil && ch.guild_id != 0 {
			if c, ok := member_color(ch.guild_id, ref.author_id); ok do name_color = c
		}
		label(pinged ? fmt.tprintf("@%s", name) : name, .Medium, 14, name_color, 18)
		spacer(.X, 4)
		content := first_line(ref.content)
		if content == "" && len(ref.attachments) > 0 do content = "Click to see attachment"
		c := label(content, .Normal, 14, T("--text-default"), 18)
		c.flags += {.Clip}
		c.semantic_size[.X] = ui.text_size(0, 0)
	}
}

// Bar above the composer while replying.
reply_bar :: proc() {
	m := find_message(ma.replying)
	if m == nil {
		ma.replying = 0
		return
	}
	s := store()
	// official: inside the composer form, 3px + 32px row, then a divider
	spacer(.Y, 3)
	bar := row("replybar")
	bar.semantic_size = {.X = ui.pct(1), .Y = ui.px(32)}
	if ui.parent(bar) {
		spacer(.X, 16)
		name := "Unknown"
		if u := dc.user_get(s, m.author_id); u != nil do name = dc.display_name(u)
		label("Replying to", .Normal, 14, T("--text-default"), 18)
		spacer(.X, 4)
		label(name, .Semibold, 14, T("--text-default"), 18)
		filler(.X)
		if m.author_id != s.me {
			at := ui.box(ma.reply_mention ? "@ ON##at" : "@ OFF##at", {.Clickable, .Draw_Text})
			at.semantic_size = {.X = ui.text_size(), .Y = ui.px(18)}
			at.style.font = F(.Bold)
			at.style.font_size = 14
			at.style.text_color = ma.reply_mention ? T("--text-brand") : T("--text-muted")
			if ui.signal(at).clicked do ma.reply_mention = !ma.reply_mention
			spacer(.X, 12)
		}
		x := ui.box("close", {.Clickable})
		x.semantic_size = {.X = ui.px(16), .Y = ui.px(16)}
		set_icon(x, "circle-x", ui.signal(x).hovering ? T("--interactive-icon-hover") : T("--interactive-icon-default"))
		if ui.signal(x).clicked do ma.replying = 0
		spacer(.X, 17)
	}
	sep := ui.box("replysep", {.Draw_Background})
	sep.semantic_size = {.X = ui.pct(1), .Y = ui.px(1)}
	sep.style.bg = T("--border-subtle")
}

// Staged attachments above the composer, removable.
uploads_bar :: proc() {
	if len(ma.uploads) == 0 do return
	bar := row("uploads", {.Draw_Background})
	bar.semantic_size = {.X = ui.pct(1), .Y = ui.px(216)}
	bar.style.bg = T("--channeltextarea-background")
	bar.style.radius = {8, 8, 0, 0}
	bar.style.child_gap = 24
	if ui.parent(bar) {
		spacer(.X, 0)
		remove := -1
		for u, i in ma.uploads {
			card := ui.box(fmt.tprintf("up%d", i), {.Draw_Background})
			card.semantic_size = {.X = ui.px(200), .Y = ui.px(200)}
			card.style.bg = T("--background-base-low")
			card.style.radius = 4
			card.layout_axis = .Y
			if ui.parent(card) {
				spacer(.Y, 140)
				r := row("name")
				r.semantic_size = {.X = ui.pct(1), .Y = ui.px(20)}
				if ui.parent(r) {
					spacer(.X, 8)
					label(u.filename, .Normal, 14, T("--text-default"), 18)
				}
				x := ui.box("rm", {.Clickable, .Draw_Background, .Floating_X, .Floating_Y})
				x.semantic_size = {.X = ui.px(24), .Y = ui.px(24)}
				x.fixed_pos = {168, 8}
				x.style.bg = T("--background-surface-high")
				x.style.radius = 4
				if ui.parent(x) {
					ic := ui.box("i", {.Floating_X, .Floating_Y})
					ic.semantic_size = {.X = ui.px(16), .Y = ui.px(16)}
					ic.fixed_pos = {4, 4}
					set_icon(ic, "trash", T("--status-danger"))
				}
				if ui.signal(x).clicked do remove = i
			}
		}
		if remove >= 0 {
			u := ma.uploads[remove]
			delete(u.path)
			delete(u.filename)
			delete(u.data)
			ordered_remove(&ma.uploads, remove)
		}
	}
}

// Send what's in the composer: text, reply, staged files.
composer_send :: proc(ch: ^dc.Channel, text: string) -> bool {
	if !net_action() do return false
	if text == "" && len(ma.uploads) == 0 do return false
	opts: dc.Send_Options
	if ma.replying != 0 {
		opts.reply_to = ma.replying
		opts.reply_guild_id = ch.guild_id
		opts.mention_replied = ma.reply_mention
	}
	files := make([]dc.Upload_File, len(ma.uploads), context.temp_allocator)
	for u, i in ma.uploads do files[i] = {filename = u.filename, mime = u.mime, data = u.data}
	if len(files) > 0 do opts.files = files
	dc.send_message(app.client, ch.id, text, opts)
	ma.replying = 0
	uploads_clear()
	return true
}

// Context menu (right click / "More"): quick reactions, add reaction, edit, reply, copy text, copy link, delete.
MENU_W :: 222
MENU_PAD :: 8
MENU_ROW_H :: 36
MENU_SEP_H :: 17
MENU_QUICK :: 44
message_menu :: proc() {
	m := find_message(ma.menu_msg)
	if m == nil {
		ma.menu_msg = 0
		return
	}
	s := store()
	own := m.author_id == s.me
	scrim := ui.box("menu_scrim", {.Clickable, .Floating_X, .Floating_Y, .Overlay})
	scrim.semantic_size = {.X = ui.px(app.ui.window.x), .Y = ui.px(app.ui.window.y)}
	if ui.signal(scrim).pressed {
		ma.menu_msg = 0
		return
	}
	ui.animate(&ma.menu_t, 1, 30)
	Item :: struct {
		label:  string,
		icon:   string,
		danger: bool,
		sub:    bool, // has a submenu chevron
		sep:    bool, // divider above
	}
	items := make([dynamic]Item, context.temp_allocator)
	append(&items, Item{label = "Add Reaction", icon = "reaction", sub = true})
	if own do append(&items, Item{label = "Edit Message", icon = "pencil", sep = true})
	append(&items, Item{label = "Reply", icon = "arrow-angle-left-up", sep = !own})
	append(&items, Item{label = "Copy Text", icon = "copy", sep = true}, Item{label = "Copy Message Link", icon = "link"})
	if own do append(&items, Item{label = "Delete Message", icon = "trash", danger = true, sep = true})
	quick := quick_reactions()
	// official: 222 wide, 8px padding, 44px quick-reaction squares, 36px rows, 17px dividers
	h := 2 * MENU_PAD + 2 + f32(len(items)) * MENU_ROW_H + (len(quick) > 0 ? MENU_QUICK + 8 : 0)
	for it in items do if it.sep do h += MENU_SEP_H
	p := ma.menu_pos
	if p.y + h > app.ui.window.y - 8 do p.y = app.ui.window.y - 8 - h
	if p.x + MENU_W > app.ui.window.x - 8 do p.x = app.ui.window.x - 8 - MENU_W
	menu := ui.box("menu", {.Draw_Background, .Draw_Border, .Draw_Shadow, .Floating_X, .Floating_Y, .Overlay, .Clickable})
	menu.semantic_size = {.X = ui.px(MENU_W), .Y = ui.px(h)}
	menu.fixed_pos = p
	menu.opacity = ma.menu_t
	menu.layout_axis = .Y
	menu.style.bg = T("--background-surface-higher")
	menu.style.border_color = T("--border-subtle")
	menu.style.border = 1
	menu.style.radius = 8
	menu.style.shadow_color = {0, 0, 0, 0.24}
	menu.style.shadow_blur = 16
	menu.style.shadow_offset = {0, 8}
	ui.signal(menu)
	if ui.parent(menu) {
		spacer(.Y, MENU_PAD + 1)
		if len(quick) > 0 {
			qr := row("quick")
			qr.semantic_size = {.X = ui.pct(1), .Y = ui.px(MENU_QUICK)}
			if ui.parent(qr) {
				spacer(.X, MENU_PAD + 1 + 8)
				for e, i in quick {
					b := ui.box(fmt.tprintf("q%d", i), {.Clickable, .Draw_Background, .Hot_Animation})
					b.semantic_size = {.X = ui.px(MENU_QUICK), .Y = ui.px(MENU_QUICK)}
					b.style.radius = 8
					b.style.bg = T("--background-mod-subtle")
					b.style.bg_hot = T("--background-mod-normal")
					b.layout_axis = .X
					b.cross_align = .Center
					if ui.signal(b).clicked {
						if net_action() do dc.add_reaction(app.client, m.channel_id, m.id, e.name, e.id)
						ma.menu_msg = 0
					}
					if ui.parent(b) {
						spacer(.X, (MENU_QUICK - 20) / 2)
						emoji_box("e", e, 20)
					}
					spacer(.X, 4)
				}
			}
			spacer(.Y, 8)
		}
		for it in items {
			if it.sep {
				sr := row(fmt.tprintf("sep_%s", it.label))
				sr.semantic_size = {.X = ui.pct(1), .Y = ui.px(MENU_SEP_H)}
				if ui.parent(sr) {
					spacer(.X, MENU_PAD + 1 + 8)
					l := ui.box("l", {.Draw_Background})
					l.semantic_size = {.X = ui.fill(), .Y = ui.px(1)}
					l.style.bg = T("--border-subtle")
					spacer(.X, MENU_PAD + 1 + 8)
				}
			}
			outer := row(fmt.tprintf("o_%s", it.label))
			outer.semantic_size = {.X = ui.pct(1), .Y = ui.px(MENU_ROW_H)}
			sig: ui.Signal
			if ui.parent(outer) {
				spacer(.X, MENU_PAD + 1)
				r := row(it.label, {.Clickable, .Draw_Background, .Hot_Animation})
				r.semantic_size = {.X = ui.fill(), .Y = ui.px(MENU_ROW_H)}
				r.style.radius = 4
				r.style.bg_hot = it.danger ? T("--status-danger") : T("--background-mod-normal")
				sig = ui.signal(r)
				if ui.parent(r) {
					spacer(.X, 8)
					c := it.danger ? T("--text-feedback-critical") : T("--interactive-text-default")
					if sig.hovering do c = it.danger ? ui.Color{1, 1, 1, 1} : T("--interactive-text-active")
					icon("ic", it.icon, 20, c)
					spacer(.X, 8)
					label(it.label, .Medium, 14, c, 18)
					filler(.X)
					if it.sub do icon("chev", "chevron-small-right", 16, c)
					spacer(.X, 8)
				}
				spacer(.X, MENU_PAD + 1)
			}
			if sig.clicked {
				switch it.label {
				case "Add Reaction":
					app.reaction_target = m.id
				case "Edit Message":
					start_edit(m)
				case "Reply":
					start_reply(m)
				case "Copy Text":
					clipboard_set(m.content)
				case "Copy Message Link":
					ch := dc.channel_get(s, m.channel_id)
					g := ch != nil && ch.guild_id != 0 ? fmt.tprint(u64(ch.guild_id)) : "@me"
					clipboard_set(fmt.tprintf("https://discord.com/channels/%s/%d/%d", g, u64(m.channel_id), u64(m.id)))
				case "Delete Message":
					if .Shift in app.ui_mods do delete_now(m)
					else do ma.deleting = m.id
				}
				ma.menu_msg = 0
			}
		}
	}
	for e in app.ui.events do if e.kind == .Key_Down && e.key == .Escape do ma.menu_msg = 0
}

delete_now :: proc(m: ^dc.Message) {
	if net_action() do dc.delete_message(app.client, m.channel_id, m.id)
}

// "Delete Message — Are you sure?" modal with a preview of the message.
delete_modal :: proc() {
	m := find_message(ma.deleting)
	if m == nil {
		ma.deleting = 0
		return
	}
	scrim := ui.box("del_scrim", {.Draw_Background, .Clickable, .Floating_X, .Floating_Y, .Overlay})
	scrim.semantic_size = {.X = ui.px(app.ui.window.x), .Y = ui.px(app.ui.window.y)}
	scrim.style.bg = {0, 0, 0, 0.7}
	if ui.signal(scrim).clicked {
		ma.deleting = 0
		return
	}
	// official: 480 wide, 24px padding, close X, a preview card, protip, two equal buttons
	W :: 480
	PAD :: 24
	d := ui.box("del", {.Draw_Background, .Draw_Border, .Floating_X, .Floating_Y, .Overlay, .Clickable})
	d.semantic_size = {.X = ui.px(W), .Y = ui.children()}
	d.fixed_pos = {(app.ui.window.x - W) / 2, (app.ui.window.y - (d.rect.y1 - d.rect.y0)) / 2}
	d.style.bg = T("--modal-background")
	d.style.border_color = T("--border-subtle")
	d.style.border = 1
	d.style.radius = 12
	d.layout_axis = .Y
	ui.signal(d)
	if ui.parent(d) {
		x := ui.box("close", {.Clickable, .Floating_X, .Floating_Y})
		x.semantic_size = {.X = ui.px(24), .Y = ui.px(24)}
		x.fixed_pos = {W - 17 - 24, 17}
		xs := ui.signal(x)
		set_icon(x, "x-large", xs.hovering ? T("--interactive-icon-hover") : T("--interactive-icon-default"))
		if xs.clicked do ma.deleting = 0
		spacer(.Y, PAD + 1)
		t := row("t")
		t.semantic_size = {.X = ui.pct(1), .Y = ui.px(24)}
		if ui.parent(t) {
			spacer(.X, PAD + 1)
			label("Delete Message", .Semibold, 20, T("--text-strong"), 24)
		}
		spacer(.Y, 8)
		q := row("q")
		q.semantic_size = {.X = ui.pct(1), .Y = ui.px(20)}
		if ui.parent(q) {
			spacer(.X, PAD + 1)
			label("Are you sure you want to delete this message?", .Normal, 16, T("--text-subtle"), 20)
		}
		spacer(.Y, 24)
		pr := row("prow")
		pr.semantic_size = {.X = ui.pct(1), .Y = ui.children()}
		if ui.parent(pr) {
			spacer(.X, PAD + 1)
			pv := row("preview", {.Draw_Background})
			pv.semantic_size = {.X = ui.fill(), .Y = ui.children()}
			pv.style.bg = T("--background-base-low")
			pv.style.radius = 8
			pv.cross_align = .Start
			if ui.parent(pv) {
				spacer(.X, 16)
				col0 := ui.box("avcol")
				col0.semantic_size = {.X = ui.px(40), .Y = ui.children()}
				if ui.parent(col0) {
					spacer(.Y, 12)
					avatar_box("av", m.author_id, 40)
					spacer(.Y, 12)
				}
				spacer(.X, 16)
				col := ui.box("col")
				col.semantic_size = {.X = ui.fill(), .Y = ui.children()}
				if ui.parent(col) {
					spacer(.Y, 10)
					hr := row("hdr")
					hr.semantic_size = {.X = ui.pct(1), .Y = ui.px(22)}
					hr.cross_align = .End
					if ui.parent(hr) {
						name := "Unknown"
						if u := dc.user_get(store(), m.author_id); u != nil do name = dc.display_name(u)
						label(name, .Medium, 16, author_color(m), 22)
						spacer(.X, 8)
						label(header_timestamp(m.id), .Medium, 12, T("--chat-text-muted"), 20)
					}
					c := label(first_line(m.content), .Normal, 16, T("--text-default"), 22)
					c.flags += {.Clip}
					spacer(.Y, 10)
				}
				spacer(.X, 16)
			}
			spacer(.X, PAD + 1)
		}
		spacer(.Y, 20)
		tip := row("tip")
		tip.semantic_size = {.X = ui.pct(1), .Y = ui.children()}
		tip.cross_align = .Start
		if ui.parent(tip) {
			spacer(.X, PAD + 1)
			tc := ui.box("tc")
			tc.semantic_size = {.X = ui.fill(), .Y = ui.children()}
			if ui.parent(tc) {
				label("Protip:", .Semibold, 14, T("--text-feedback-positive"), 18)
				body := ui.box("tipbody", {.Wrap_Text})
				body.semantic_size = {.X = ui.pct(1), .Y = ui.text_size()}
				body.style.line_height = 16
				body.style.text_color = T("--text-default")
				spans := make([]ui.Span, 3, context.temp_allocator)
				spans[0] = {text = "You can hold down shift when clicking ", font = F(.Normal), size = 14}
				spans[1] = {text = "delete message", font = F(.Bold), size = 14}
				spans[2] = {text = " to bypass this confirmation entirely.", font = F(.Normal), size = 14}
				ui.set_spans(body, spans)
			}
			spacer(.X, PAD + 1)
		}
		spacer(.Y, 19)
		btns := row("btns")
		btns.semantic_size = {.X = ui.pct(1), .Y = ui.px(40)}
		btns.style.child_gap = 8
		if ui.parent(btns) {
			spacer(.X, PAD + 1 - 8)
			cancel := ui.box("Cancel##c", {.Clickable, .Draw_Background, .Draw_Text, .Hot_Animation})
			cancel.semantic_size = {.X = ui.fill(), .Y = ui.px(40)}
			cancel.style.radius = 8
			cancel.style.font = F(.Medium)
			cancel.style.font_size = 16
			cancel.style.text_align = .Center
			cancel.style.text_color = T("--text-strong")
			cancel.style.bg = T("--background-mod-normal")
			cancel.style.bg_hot = T("--background-mod-strong")
			if ui.signal(cancel).clicked do ma.deleting = 0
			del := ui.box("Delete##d", {.Clickable, .Draw_Background, .Draw_Text, .Hot_Animation})
			del.semantic_size = {.X = ui.fill(), .Y = ui.px(40)}
			del.style.radius = 8
			del.style.font = F(.Medium)
			del.style.font_size = 16
			del.style.text_align = .Center
			del.style.text_color = {1, 1, 1, 1}
			del.style.bg = T("--status-danger")
			del.style.bg_hot = T("--control-critical-primary-background-hover")
			if ui.signal(del).clicked {
				delete_now(m)
				ma.deleting = 0
			}
			spacer(.X, PAD + 1 - 8)
		}
		spacer(.Y, PAD + 1)
	}
	for e in app.ui.events {
		if e.kind == .Key_Down && e.key == .Escape do ma.deleting = 0
		if e.kind == .Key_Down && e.key == .Enter {
			delete_now(m)
			ma.deleting = 0
		}
	}
}
