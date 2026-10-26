package app

import "core:fmt"
import "core:os"
import "core:path/filepath"
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
	bar := row("toolbar", {.Draw_Background, .Draw_Border, .Draw_Shadow, .Floating_X, .Floating_Y, .Clickable})
	n := own ? 4 : 3
	w := f32(n) * 32 + 8
	bar.semantic_size = {.X = ui.px(w), .Y = ui.px(36)}
	bar.fixed_pos = {ui.top_parent().rect.x1 - ui.top_parent().rect.x0 - w - 16, -16}
	bar.style.bg = T("--background-surface-higher")
	bar.style.border_color = T("--border-subtle")
	bar.style.border = 1
	bar.style.radius = 8
	bar.style.shadow_color = {0, 0, 0, 0.16}
	bar.style.shadow_blur = 4
	ui.signal(bar)
	if ui.parent(bar) {
		spacer(.X, 4)
		names := own ? []string{"reaction", "arrow-angle-left-up", "pencil", "more-horizontal"} : []string{"reaction", "arrow-angle-left-up", "more-horizontal"}
		for name in names {
			b := ui.box(name, {.Clickable, .Draw_Background, .Hot_Animation})
			b.semantic_size = {.X = ui.px(32), .Y = ui.px(32)}
			b.style.radius = 6
			b.style.bg_hot = T("--background-mod-subtle")
			b.layout_axis = .X
			b.cross_align = .Center
			sig := ui.signal(b)
			if ui.parent(b) {
				spacer(.X, 6)
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
	box := row("editbox", {.Draw_Background, .Clickable})
	box.semantic_size = {.X = ui.pct(1), .Y = ui.children()}
	box.style.bg = T("--channeltextarea-background")
	box.style.radius = 8
	box.cross_align = .Start
	if ui.parent(box) {
		spacer(.X, 16)
		res := text_field("edit", &ma.edit_editor, "", true)
		spacer(.X, 16)
		switch res {
		case .Submit:
			text := strings.trim_space(ui.editor_text(&ma.edit_editor))
			if text == "" {
				ma.deleting = m.id
			} else if text != m.content && app.client != nil {
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
		label("escape to ", .Normal, 12, T("--text-default"), 16)
		label("cancel", .Normal, 12, T("--text-link"), 16)
		label(" • enter to ", .Normal, 12, T("--text-default"), 16)
		label("save", .Normal, 12, T("--text-link"), 16)
	}
}

// The referenced message preview above a reply: curved spine, small avatar, name, one line of content.
reply_preview :: proc(m: ^dc.Message) {
	s := store()
	ref := find_message(m.referenced_id)
	r := row("replyref")
	r.semantic_size = {.X = ui.pct(1), .Y = ui.px(22)}
	if ui.parent(r) {
		spine := ui.box("spine", {.Draw_Border, .Floating_X, .Floating_Y})
		spine.semantic_size = {.X = ui.px(33), .Y = ui.px(12)}
		spine.fixed_pos = {-MSG_GUTTER + 36, 8}
		spine.style.border = 2
		spine.style.border_color = T("--border-strong")
		spine.style.radius = {6, 0, 0, 0}
		if ref == nil {
			label("Original message was deleted", .Normal, 14, T("--text-muted"), 18)
			return
		}
		avatar_box("av", ref.author_id, 16)
		spacer(.X, 4)
		name := "Unknown"
		if u := dc.user_get(s, ref.author_id); u != nil do name = dc.display_name(u)
		label(fmt.tprintf("@%s", name), .Medium, 14, author_color(ref), 18)
		spacer(.X, 4)
		content := first_line(ref.content)
		if content == "" && len(ref.attachments) > 0 do content = "Click to see attachment"
		c := label(content, .Normal, 14, T("--text-muted"), 18)
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
	bar := row("replybar", {.Draw_Background})
	bar.semantic_size = {.X = ui.pct(1), .Y = ui.px(34)}
	bar.style.bg = T("--background-base-low")
	bar.style.radius = {8, 8, 0, 0}
	if ui.parent(bar) {
		spacer(.X, 16)
		name := "Unknown"
		if u := dc.user_get(s, m.author_id); u != nil do name = dc.display_name(u)
		label("Replying to ", .Normal, 14, T("--text-muted"), 18)
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
		set_icon(x, "circle-x", T("--interactive-icon-default"))
		if ui.signal(x).clicked do ma.replying = 0
		spacer(.X, 16)
	}
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
	if app.client == nil do return false
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

// Context menu (right click / "More"): reply, edit, copy text, copy link, copy id, delete.
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
		danger: bool,
	}
	items := make([dynamic]Item, context.temp_allocator)
	append(&items, Item{"Add Reaction", false})
	if own do append(&items, Item{"Edit Message", false})
	append(&items, Item{"Reply", false}, Item{"Copy Text", false}, Item{"Copy Message Link", false}, Item{"Copy Message ID", false})
	if own do append(&items, Item{"Delete Message", true})
	h := f32(len(items)) * 32 + 16
	p := ma.menu_pos
	if p.y + h > app.ui.window.y - 8 do p.y = app.ui.window.y - 8 - h
	if p.x + 220 > app.ui.window.x - 8 do p.x = app.ui.window.x - 228
	menu := ui.box("menu", {.Draw_Background, .Draw_Border, .Draw_Shadow, .Floating_X, .Floating_Y, .Overlay, .Clickable})
	menu.semantic_size = {.X = ui.px(220), .Y = ui.px(h)}
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
		spacer(.Y, 8)
		for it in items {
			r := row(it.label, {.Clickable, .Draw_Background, .Hot_Animation})
			r.semantic_size = {.X = ui.pct(1), .Y = ui.px(32)}
			r.style.radius = 4
			r.style.bg_hot = it.danger ? T("--status-danger") : T("--background-mod-normal")
			sig := ui.signal(r)
			if ui.parent(r) {
				spacer(.X, 8)
				c := it.danger ? T("--text-feedback-critical") : T("--interactive-text-default")
				if sig.hovering do c = it.danger ? ui.Color{1, 1, 1, 1} : T("--interactive-text-active")
				label(it.label, .Medium, 14, c, 18)
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
				case "Copy Message ID":
					clipboard_set(fmt.tprint(u64(m.id)))
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
	if app.client != nil do dc.delete_message(app.client, m.channel_id, m.id)
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
	W :: 440
	d := ui.box("del", {.Draw_Background, .Draw_Border, .Floating_X, .Floating_Y, .Overlay, .Clickable})
	d.semantic_size = {.X = ui.px(W), .Y = ui.children()}
	d.fixed_pos = {(app.ui.window.x - W) / 2, app.ui.window.y / 2 - 140}
	d.style.bg = T("--modal-background")
	d.style.border_color = T("--border-subtle")
	d.style.border = 1
	d.style.radius = 12
	d.layout_axis = .Y
	ui.signal(d)
	if ui.parent(d) {
		spacer(.Y, 24)
		t := row("t")
		t.semantic_size = {.X = ui.pct(1), .Y = ui.px(24)}
		if ui.parent(t) {
			spacer(.X, 24)
			label("Delete Message", .Semibold, 20, T("--text-strong"), 24)
		}
		spacer(.Y, 12)
		q := row("q")
		q.semantic_size = {.X = ui.pct(1), .Y = ui.px(20)}
		if ui.parent(q) {
			spacer(.X, 24)
			label("Are you sure you want to delete this message?", .Normal, 16, T("--text-default"), 20)
		}
		spacer(.Y, 16)
		pv := row("preview", {.Draw_Background, .Draw_Border})
		pv.semantic_size = {.X = ui.pct(1), .Y = ui.px(64)}
		pv.style.bg = T("--background-base-lower")
		pv.style.border = 1
		pv.style.border_color = T("--border-subtle")
		pv.style.radius = 8
		if ui.parent(pv) {
			spacer(.X, 16)
			avatar_box("av", m.author_id, 40)
			spacer(.X, 16)
			c := label(first_line(m.content), .Normal, 16, T("--text-default"), 22)
			c.flags += {.Clip}
		}
		spacer(.Y, 24)
		btns := row("btns", {.Draw_Background})
		btns.semantic_size = {.X = ui.pct(1), .Y = ui.px(68)}
		btns.style.bg = T("--modal-footer-background")
		btns.style.radius = {0, 0, 12, 12}
		if ui.parent(btns) {
			filler(.X)
			cancel := ui.box("Cancel##c", {.Clickable, .Draw_Background, .Draw_Text, .Hot_Animation})
			cancel.semantic_size = {.X = ui.text_size(16), .Y = ui.px(38)}
			cancel.style.radius = 8
			cancel.style.font = F(.Medium)
			cancel.style.font_size = 14
			cancel.style.text_align = .Center
			cancel.style.text_color = T("--text-default")
			cancel.style.bg = T("--background-mod-normal")
			cancel.style.bg_hot = T("--background-mod-strong")
			if ui.signal(cancel).clicked do ma.deleting = 0
			spacer(.X, 12)
			del := ui.box("Delete##d", {.Clickable, .Draw_Background, .Draw_Text, .Hot_Animation})
			del.semantic_size = {.X = ui.text_size(16), .Y = ui.px(38)}
			del.style.radius = 8
			del.style.font = F(.Medium)
			del.style.font_size = 14
			del.style.text_align = .Center
			del.style.text_color = {1, 1, 1, 1}
			del.style.bg = T("--status-danger")
			del.style.bg_hot = with_alpha(T("--status-danger"), 0.85)
			if ui.signal(del).clicked {
				delete_now(m)
				ma.deleting = 0
			}
			spacer(.X, 24)
		}
	}
	for e in app.ui.events {
		if e.kind == .Key_Down && e.key == .Escape do ma.deleting = 0
		if e.kind == .Key_Down && e.key == .Enter {
			delete_now(m)
			ma.deleting = 0
		}
	}
}
