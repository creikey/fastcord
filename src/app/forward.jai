// Forward: send a message on to another channel or DM of the same connection, with an optional note
// sent after it as a message of its own.

Forward :: struct {
	msg: dc.Snowflake; // the message forwarded; 0 when closed
	channel: dc.Snowflake; // where it is
	search: ui.Editor;
	note: ui.Editor;
	dest: dc.Snowflake; // the picked channel; 0 until one is
	on_note: bool; // which field has focus
}

fwd: Forward;

forward_open :: (m: *dc.Message) {
	fwd.msg, fwd.channel, fwd.dest, fwd.on_note = m.id, m.channel_id, 0, false;
	ui.editor_set_text(*fwd.search, "");
	ui.editor_set_text(*fwd.note, "");
}

// can_forward: only plain messages and replies that the server has, as the official menu offers it. An
// encrypted one goes re-encrypted for its destination (encrypted_forward), so only once we've opened it.
can_forward :: (m: *dc.Message) -> bool {
	return !m.pending && !m.failed && !m.forwarded && (m.kind == 0 || m.kind == 19) && (!encrypted_packet(m.channel_id, m.content) || encrypted_editable(m));
}

Forward_Item :: struct {
	id: dc.Snowflake;
	name: string;
	sub: string;
	score: int;
}

// The best destinations for the query, best first: DMs, then channels we may post in.
forward_items :: (query: string) -> []Forward_Item {
	MAX :: 8;
	top: [..]Forward_Item;
	top.allocator = temp;
	add :: (top: *[..]Forward_Item, item: Forward_Item) {
		if item.score < 0 return;
		at := top.count;
		while at > 0 && top.*[at - 1].score < item.score at -= 1;
		if at >= MAX return;
		array_insert_at(top, item, at);
		if top.count > MAX top.count = MAX;
	}
	s := store();
	for cid: s.private_channels {
		ch := dc.channel_get(s, cid);
		if ch == null continue;
		name := dm_name(ch);
		sc := fuzzy_score(query, name);
		add(*top, .{id = cid, name = name, score = ifx sc >= 0 then sc + 5 else -1});
	}
	for gid: guild_order() {
		g := dc.guild_get(s, gid);
		if g == null continue;
		for cid: dc.guild_channels_sorted(s, gid) {
			ch := dc.channel_get(s, cid);
			if ch == null || (ch.kind != .Guild_Text && ch.kind != .Guild_Announcement) continue;
			if !dc.has_permission(dc.channel_permissions(s, cid), dc.PERM_VIEW_CHANNEL | dc.PERM_SEND_MESSAGES) continue;
			add(*top, .{id = cid, name = tprint("#%", ch.name), sub = g.name, score = fuzzy_score(query, ch.name)});
		}
	}
	return top;
}

forward_send :: () {
	s := store();
	src := dc.channel_get(s, fwd.channel);
	opts: dc.Send_Options;
	opts.forward_message, opts.forward_channel, opts.forward_guild = fwd.msg, fwd.channel, ifx src then src.guild_id else 0;
	m := find_message(fwd.msg);
	dest := dc.channel_get(s, fwd.dest);
	if net_action() && m && dest {
		if encrypted_packet(m.channel_id, m.content) encrypted_forward(m, dest);
		else dc.send_message(app.client, fwd.dest, "", opts);
		note := trim(ui.editor_text(*fwd.note));
		if note && encrypting(dest) encrypted_send(dest, note, false);
		else if note dc.send_message(app.client, fwd.dest, note);
	}
	fwd.msg = 0;
	app.ui.focus = 0;
}

forward_modal :: () {
	scrim := ui.box("fwd_scrim", .Draw_Background | .Clickable | .Floating_X | .Floating_Y | .Overlay);
	scrim.semantic_size = .[ui.px(app.ui.window.x), ui.px(app.ui.window.y)];
	scrim.style.bg = .{0, 0, 0, 0.7};
	if ui.signal(scrim).clicked {
		fwd.msg = 0;
		return;
	}
	W :: 480;
	PAD :: 24;
	d := ui.box("fwdmodal", .Draw_Background | .Draw_Border | .Floating_X | .Floating_Y | .Overlay | .Clickable);
	d.semantic_size = .[ui.px(W), ui.children()];
	d.fixed_pos = .{(app.ui.window.x - W) / 2, (app.ui.window.y - (d.rect.y1 - d.rect.y0)) / 2};
	d.style.bg = T("--modal-background");
	d.style.border_color = T("--border-subtle");
	d.style.border = 1;
	d.style.radius = all4(12);
	d.layout_axis = .Y;
	ui.signal(d);
	ui.push_parent(d);
	defer ui.pop_parent();

	for * e: app.ui.events {
		if e.consumed || e.kind != .Key_Down continue;
		if e.key == .Tab { fwd.on_note = !fwd.on_note; e.consumed = true; }
		if e.key == .Escape { fwd.msg = 0; e.consumed = true; }
	}
	items := forward_items(trim(ui.editor_text(*fwd.search)));
	send := false;

	input :: (id: string, ed: *ui.Editor, placeholder: string, is_note: bool) -> ui.Edit_Result {
		field := row(id, .Draw_Background | .Draw_Border | .Clickable);
		field.semantic_size = .[ui.pct(1), ui.px(40)];
		field.style.bg = T("--input-background-default");
		focused := fwd.on_note == is_note;
		field.style.border_color = ifx focused then T("--input-border-active") else T("--border-subtle");
		field.style.border = 1;
		field.style.radius = all4(8);
		field.hover_cursor = .IBeam;
		if ui.signal(field).pressed fwd.on_note = is_note;
		if focused app.ui.focus = field.key; // Else the composer under the modal keeps the keys.
		ui.parent(field); defer ui.pop_parent();
		spacer(.X, 12);
		res := text_field("field", ed, placeholder, focused, 16, 20, 10, T("--input-placeholder-text-default"));
		spacer(.X, 12);
		return res;
	}
	padded :: (id: string) -> *ui.Box {
		r := row(id);
		r.semantic_size = .[ui.pct(1), ui.children()];
		ui.push_parent(r);
		spacer(.X, PAD);
		col := ui.box("col");
		col.semantic_size = .[ui.fill(), ui.children()];
		col.layout_axis = .Y;
		ui.push_parent(col);
		return r;
	}
	unpad :: () { ui.pop_parent(); spacer(.X, PAD); ui.pop_parent(); }

	spacer(.Y, PAD);
	padded("head");
	label(L("Forward To"), .Semibold, 20, T("--text-strong"), 24);
	spacer(.Y, 4);
	label(L("Select where you want to share this message."), .Normal, 14, T("--text-muted"), 18);
	spacer(.Y, 16);
	res := input("search", *fwd.search, L("Search"), false);
	if res == .Submit && items fwd.dest = items[0].id;
	if res == .Escape fwd.msg = 0;
	unpad();
	spacer(.Y, 8);
	for items {
		r := row(tprint("dest_%", it.id), .Clickable | .Draw_Background | .Hot_Animation);
		r.semantic_size = .[ui.pct(1), ui.px(40)];
		r.cross_align = .Center;
		r.style.bg_hot = T("--background-mod-normal");
		if it.id == fwd.dest r.style.bg = T("--background-mod-subtle");
		{ ui.parent(r); defer ui.pop_parent();
			spacer(.X, PAD);
			label(it.name, .Medium, 16, T("--text-default"), 20);
			if it.sub { spacer(.X, 8); label(it.sub, .Normal, 14, T("--text-muted"), 18); }
			filler(.X);
			if it.id == fwd.dest icon("check", "checkmark-small", 20, T("--background-brand"));
			spacer(.X, PAD);
		}
		if ui.signal(r).clicked fwd.dest = ifx fwd.dest == it.id then 0 else it.id;
	}
	if !items {
		padded("none");
		label(L("No results"), .Normal, 14, T("--text-muted"), 40);
		unpad();
	}
	spacer(.Y, 12);
	padded("note");
	res = input("note", *fwd.note, L("Add an optional message..."), true);
	if res == .Submit && fwd.dest send = true;
	if res == .Escape fwd.msg = 0;
	src := find_message(fwd.msg);
	if src && fwd.dest && encrypted_packet(src.channel_id, src.content) && !encrypting(dc.channel_get(store(), fwd.dest)) {
		// Leaving E2E: said before it goes.
		spacer(.Y, 12);
		w := row("leaving");
		w.semantic_size = .[ui.pct(1), ui.children()];
		{ ui.parent(w); defer ui.pop_parent();
			icon("warn", "warning", 16, T("--text-feedback-warning"));
			spacer(.X, 8);
			who := ifx on_hosted() then L("This message is end-to-end encrypted. Forwarding it here sends it unencrypted, so the server's host can read it.") else L("This message is end-to-end encrypted. Forwarding it here sends it unencrypted, so Discord can read it.");
			p := ui.box(tprint("%##leavingtext", who), .Draw_Text | .Wrap_Text);
			p.semantic_size = .[ui.fill(), ui.text_size()];
			p.style.font = F(.Normal);
			p.style.font_size = 14;
			p.style.line_height = 18;
			p.style.text_color = T("--text-default");
		}
	}
	spacer(.Y, 16);
	buttons := row("buttons");
	buttons.semantic_size = .[ui.pct(1), ui.children()];
	{ ui.parent(buttons); defer ui.pop_parent();
		filler(.X);
		if adm_button("cancel", L("Cancel"), .Secondary) fwd.msg = 0;
		spacer(.X, 8);
		if adm_button("send", L("Send"), .Primary, enabled = fwd.dest != 0) send = true;
	}
	unpad();
	spacer(.Y, PAD);
	if send && fwd.msg && fwd.dest forward_send();
}
