// Bottles: a message sealed for the people its sender picks, posted in any channel, DM or group. Anyone
// sees the bottle; only its readers can open it. The `e2e` module seals it under a key used once (a
// Bottle packet, `fc-` text after BOTTLE_NOTE) and gives each reader that key as a hidden, silent message
// of their encrypted 1:1 DM with the sender, so a reader must have one. Open looks the key up, and when it
// isn't there yet, loads that DM to find it. A bottle opens only as from the one who gave its key.

BOTTLE_NOTE :: "Message in a bottle from fastcord (creikey.com/fastcord). Only the people it's for can open it.\n";
BOTTLE_PICKS :: 6;

Bottle_Open :: struct {
	clicked: bool;
	pending: bool;
	result: e2e.Result;
	text: string;
	generation: int; // bottles.generation when a No_Session result came back.
	looked: bool;    // The DM with its author was searched for the key.
	dm: dc.Snowflake; // That DM, while it loads and its packets open.
}

Bottle_Job :: struct {
	r: *e2e.Request;
	message: dc.Snowflake; // Unbottle: the bottle's message.
	readers: [..]dc.Snowflake; // Bottle: who gets the key.
}

Bottle_State :: struct {
	msg: dc.Snowflake; // The message being bottled; 0 when the modal is closed.
	text: string;
	place: ui.Editor;
	reader: ui.Editor;
	on_readers: bool;
	dest: dc.Snowflake;
	readers: [..]dc.Snowflake;

	opened: Table(dc.Snowflake, Bottle_Open); // By message ID.
	jobs: [..]Bottle_Job;
	generation: int; // Bumped when a Bottle_Key arrives, so bottles that had none look again.
}

bottles: Bottle_State;

is_bottle :: (content: string) -> bool { return begins_with(content, BOTTLE_NOTE); }

// bottle_text: what goes in a bottle from m (empty: it can't be bottled): its text, opened if encrypted.
bottle_text :: (m: *dc.Message) -> string {
	if m.pending || m.failed || m.forwarded || (m.kind != 0 && m.kind != 19) || is_bottle(m.content) || !e2e_db return "";
	if !encrypted_packet(m.channel_id, m.content) return m.content;
	return ifx encrypted_editable(m) then shown_text(m.id, m.channel_id, m.content) else "";
}

bottle_start :: (m: *dc.Message) {
	free(bottles.text);
	bottles.msg, bottles.text, bottles.dest, bottles.on_readers = m.id, copy_string(bottle_text(m)), 0, false;
	bottles.readers.count = 0;
	ui.editor_set_text(*bottles.place, "");
	ui.editor_set_text(*bottles.reader, "");
}

bottle_close :: () {
	bottles.msg = 0;
	app.ui.focus = 0;
}

// bottle_dm: the 1:1 DM with user on this connection, or 0.
bottle_dm :: (user: dc.Snowflake) -> dc.Snowflake {
	s := store();
	for s.private_channels {
		ch := dc.channel_get(s, it);
		if ch && ch.kind == .DM && ch.recipient_ids.count == 1 && ch.recipient_ids[0] == user return it;
	}
	return 0;
}

// bottle_candidates: who may be a reader, best match first: each person we have an encrypted 1:1 DM with.
bottle_candidates :: (query: string) -> []dc.Snowflake {
	Pick :: struct { user: dc.Snowflake; score: int; }
	picks: [..]Pick;
	picks.allocator = temp;
	s := store();
	for s.private_channels {
		ch := dc.channel_get(s, it);
		if !ch || ch.kind != .DM || ch.recipient_ids.count != 1 || !encrypted_channel(ch.id).has_session continue;
		sc := fuzzy_score(query, dm_name(ch));
		if sc < 0 && !array_find(bottles.readers, ch.recipient_ids[0]) continue;
		at := picks.count;
		while at > 0 && picks[at - 1].score < sc at -= 1;
		array_insert_at(*picks, .{ch.recipient_ids[0], sc}, at);
	}
	out := NewArray(min(picks.count, BOTTLE_PICKS), dc.Snowflake,, temp);
	for * out it.* = picks[it_index].user;
	return out;
}

bottle_send :: () {
	if !bottles.dest || !bottles.readers || !bottles.text || !net_action() return;
	if !identity_ready() { toast_show(L("Encryption is still starting. Try again in a moment."), false); return; }
	r := e2e.request(.Bottle, conversation(bottles.dest, limit = fc_text.MAX_PACKET), bottles.text);
	r.me = my_identity();
	j := array_add(*bottles.jobs);
	j.r = r;
	array_add(*j.readers, ..bottles.readers);
	e2e.submit(e2e_db, r);
	bottle_close();
}

// bottle_frame takes finished bottle requests: a sealed bottle is posted and its key given to each reader;
// an opened one is kept for its message.
bottle_frame :: () {
	for j: bottles.jobs {
		if !e2e.is_done(j.r) continue;
		r := j.r;
		if r.failed log_error("e2e: %", e2e_db.error);
		else if r.op == .Bottle bottle_post(r, j.readers);
		else {
			sh := find_or_add(*bottles.opened, j.message);
			free(sh.text);
			sh.pending, sh.result, sh.text, sh.generation = false, r.result, copy_string(r.out_text), bottles.generation;
			app.ui.animating = true;
		}
		e2e.free_request(r);
		array_free(j.readers);
		remove j;
	}
}

bottle_post :: (r: *e2e.Request, readers: []dc.Snowflake) {
	if r.result != .Ok { toast_show(ifx r.result == .Too_Long then L("That's too long for a bottle.") else L("Couldn't seal the bottle."), false); return; }
	c := app.client;
	if !c || carrier_client(r.conv.carrier) != c return;
	// The keys go out after the bottle: each Send is posted once it's committed (send_packet).
	dc.send_message(c, dc.parse_snowflake(r.conv.id), tprint("%1%2", BOTTLE_NOTE, fc_text.encode(xx r.packet,, temp)));
	for readers {
		dm := bottle_dm(it);
		if !dm continue;
		g := e2e.request(.Send, conversation(dm), r.out_text);
		g.me, g.content, g.silent = my_identity(), e2e.Content.Bottle_Key, true;
		e2e_submit(g);
	}
}

// bottle_key_came: a reader got a key, so bottles that had none look again.
bottle_key_came :: () { bottles.generation += 1; }

// bottle_body draws a bottle in place of its text, with its Open button and why it can't open, or returns
// what it held, once opened, for message_body to draw. false leaves the text to message_body.
bottle_body :: (m: *dc.Message) -> handled: bool, plaintext: string {
	if !is_bottle(m.content) return false, "";
	packet, ok := fc_text.decode(advance(m.content, BOTTLE_NOTE.count));
	ok = ok && packet.count > e2e.BOTTLE_OVERHEAD && packet[0] == e2e.VERSION && packet[1] == xx e2e.Kind.Bottle;
	sh := find_or_add(*bottles.opened, m.id);
	mine := m.author_id == store().me;
	ask :: () #expand {
		if !e2e_db || !identity_ready() return;
		`sh.pending = true;
		r := e2e.request(.Unbottle, conversation(`m.channel_id), packet = xx `packet);
		r.from = sprint("%", `m.author_id);
		array_add(*bottles.jobs, .{r = r, message = `m.id});
		e2e.submit(e2e_db, r);
	}
	if ok && sh.clicked && !sh.pending && sh.result == .No_Session && sh.generation != bottles.generation ask();
	if ok && sh.dm && !sh.pending bottle_look(sh, m);
	if sh.clicked && !sh.pending && sh.result == .Ok return true, sh.text;

	card := row("bottle", .Draw_Background | .Draw_Border);
	card.semantic_size = .[ui.children(), ui.children()];
	card.style.bg = T("--background-base-lower");
	card.style.border_color = T("--border-subtle");
	card.style.border = 1;
	card.style.radius = all4(8);
	{ ui.parent(card); defer ui.pop_parent();
		spacer(.X, 12);
		icon("icon", "lock", 20, T("--text-muted"));
		spacer(.X, 10);
		col := ui.box("col");
		col.semantic_size = .[ui.children(), ui.children()];
		col.layout_axis = .Y;
		{ ui.parent(col); defer ui.pop_parent();
			spacer(.Y, 10);
			label(L("Message in a Bottle"), .Semibold, chat_px(15), T("--text-strong"), chat_px(20));
			why := "";
			if !ok                                   why = L("This bottle is damaged.");
			else if sh.pending || sh.dm              why = L("Opening…");
			else if !sh.clicked                      why = L("Only the people it's for can open it.");
			else if sh.result == .No_Session && mine why = L("This device doesn't have its key.");
			else if sh.result == .No_Session         why = L("It isn't for you, or its key hasn't reached you yet.");
			else                                     why = L("This bottle is damaged.");
			label(why, .Normal, chat_px(14), T("--text-muted"), chat_px(18));
			spacer(.Y, 10);
		}
		spacer(.X, 16);
		if ok && !sh.clicked && adm_button("open", L("Open"), .Primary) && e2e_db && identity_ready() {
			sh.clicked = true;
			ask();
		}
		spacer(.X, 12);
	}
	// No key here yet: it may be in the DM with the author, not loaded or not yet opened. Once.
	if ok && sh.clicked && !sh.pending && sh.result == .No_Session && !mine && !sh.looked {
		sh.looked = true;
		sh.dm = bottle_dm(m.author_id);
		if sh.dm && app.client {
			l := table_find_pointer(*store().messages, sh.dm);
			if !l || (!l.loaded && !l.loading) dc.fetch_messages(app.client, sh.dm);
		}
	}
	return true, "";
}

// bottle_look opens the packets of the DM where a bottle's key may be. Once they all have, the bottle is
// asked again: a key among them was kept, and bumped the generation.
bottle_look :: (sh: *Bottle_Open, m: *dc.Message) {
	l := table_find_pointer(*store().messages, sh.dm);
	if l && l.loading return;
	settled := true;
	if l for * l.messages if !it.pending && it.author_id == m.author_id && begins_with(it.content, fc_text.PREFIX) {
		o := encrypted_open(it.id, it.channel_id, it.content, it.author_id, it.edited_timestamp);
		if !o || o.pending settled = false;
	}
	if !settled return;
	sh.dm = 0;
	sh.generation -= 1; // Ask once more, whatever came.
}

// shown_bottle: a bottle's text as drawn outside the message list: what it held once opened.
shown_bottle :: (id: dc.Snowflake) -> string {
	sh := table_find_pointer(*bottles.opened, id);
	return ifx sh && sh.clicked && !sh.pending && sh.result == .Ok then sh.text else L("Message in a bottle");
}

bottle_modal :: () {
	scrim := ui.box("bottle_scrim", .Draw_Background | .Clickable | .Floating_X | .Floating_Y | .Overlay);
	scrim.semantic_size = .[ui.px(app.ui.window.x), ui.px(app.ui.window.y)];
	scrim.style.bg = .{0, 0, 0, 0.7};
	if ui.signal(scrim).clicked { bottle_close(); return; }
	W :: 480;
	PAD :: 24;
	d := ui.box("bottlemodal", .Draw_Background | .Draw_Border | .Floating_X | .Floating_Y | .Overlay | .Clickable);
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
		if e.key == .Tab { bottles.on_readers = !bottles.on_readers; e.consumed = true; }
		if e.key == .Escape { bottle_close(); e.consumed = true; }
	}
	input :: (id: string, ed: *ui.Editor, placeholder: string, readers: bool) -> ui.Edit_Result {
		field := row(id, .Draw_Background | .Draw_Border | .Clickable);
		field.semantic_size = .[ui.pct(1), ui.px(40)];
		field.style.bg = T("--input-background-default");
		focused := bottles.on_readers == readers;
		field.style.border_color = ifx focused then T("--input-border-active") else T("--border-subtle");
		field.style.border = 1;
		field.style.radius = all4(8);
		field.hover_cursor = .IBeam;
		if ui.signal(field).pressed bottles.on_readers = readers;
		if focused app.ui.focus = field.key;
		ui.parent(field); defer ui.pop_parent();
		spacer(.X, 12);
		res := text_field("field", ed, placeholder, focused, 16, 20, 10, T("--input-placeholder-text-default"));
		spacer(.X, 12);
		return res;
	}
	padded :: (id: string) {
		r := row(id);
		r.semantic_size = .[ui.pct(1), ui.children()];
		ui.push_parent(r);
		spacer(.X, PAD);
		col := ui.box("col");
		col.semantic_size = .[ui.fill(), ui.children()];
		col.layout_axis = .Y;
		ui.push_parent(col);
	}
	unpad :: () { ui.pop_parent(); spacer(.X, PAD); ui.pop_parent(); }
	wrapped :: (id: string, text: string, color: ui.Color) {
		p := ui.box(tprint("%##%", text, id), .Draw_Text | .Wrap_Text);
		p.semantic_size = .[ui.pct(1), ui.text_size()];
		p.style.font = F(.Normal);
		p.style.font_size = 14;
		p.style.line_height = 18;
		p.style.text_color = color;
	}
	pick_row :: (id: string, selected: bool) -> bool {
		r := row(id, .Clickable | .Draw_Background | .Hot_Animation);
		r.semantic_size = .[ui.pct(1), ui.px(40)];
		r.style.bg_hot = T("--background-mod-normal");
		if selected r.style.bg = T("--background-mod-subtle");
		ui.push_parent(r);
		spacer(.X, PAD);
		return ui.signal(r).clicked;
	}
	pick_end :: (selected: bool) {
		filler(.X);
		if selected icon("check", "checkmark-small", 20, T("--background-brand"));
		spacer(.X, PAD);
		ui.pop_parent();
	}
	send := false;

	spacer(.Y, PAD);
	padded("head");
	label(L("Put in a Bottle"), .Semibold, 20, T("--text-strong"), 24);
	spacer(.Y, 4);
	wrapped("sub", L("Anyone where you post it sees the bottle. Only the people you pick can open it."), T("--text-muted"));
	spacer(.Y, 12);
	wrapped("quote", ellipsize(first_line(bottles.text), .Normal, 14, W - 2 * PAD), T("--text-default"));
	spacer(.Y, 16);
	label(L("Post In"), .Semibold, 12, T("--text-strong"), 16);
	spacer(.Y, 6);
	// A hosted server's DMs carry only E2E packets: there, bottles go in its channels.
	places: [..]Forward_Item;
	places.allocator = temp;
	for forward_items(trim(ui.editor_text(*bottles.place))) {
		ch := dc.channel_get(store(), it.id);
		if places.count < 4 && !(on_hosted() && ch && !ch.guild_id) array_add(*places, it);
	}
	res := input("place", *bottles.place, L("Search"), false);
	if res == .Submit && places bottles.dest = places[0].id;
	unpad();
	spacer(.Y, 4);
	for places {
		if pick_row(tprint("dest_%", it.id), it.id == bottles.dest) bottles.dest = ifx bottles.dest == it.id then 0 else it.id;
		label(it.name, .Medium, 16, T("--text-default"), 20);
		if it.sub { spacer(.X, 8); label(it.sub, .Normal, 14, T("--text-muted"), 18); }
		pick_end(it.id == bottles.dest);
	}
	spacer(.Y, 12);
	padded("readers");
	label(L("Who Can Open It"), .Semibold, 12, T("--text-strong"), 16);
	spacer(.Y, 6);
	people := bottle_candidates(trim(ui.editor_text(*bottles.reader)));
	res = input("reader", *bottles.reader, L("Search"), true);
	if res == .Submit && people && !array_find(bottles.readers, people[0]) array_add(*bottles.readers, people[0]);
	unpad();
	spacer(.Y, 4);
	for people {
		picked, at := array_find(bottles.readers, it);
		if pick_row(tprint("reader_%", it), picked) {
			if picked array_ordered_remove_by_index(*bottles.readers, at);
			else array_add(*bottles.readers, it);
		}
		avatar_with_status("av", it, 24, T("--modal-background"));
		spacer(.X, 10);
		label(dc.user_name(store(), it, 0, "unknown"), .Medium, 16, T("--text-default"), 20);
		pick_end(picked);
	}
	if !people {
		padded("none");
		spacer(.Y, 8);
		wrapped("nonetext", L("A reader needs an encrypted DM with you. Turn on encryption in your DM with them first."), T("--text-muted"));
		unpad();
	}
	spacer(.Y, 16);
	padded("buttons");
	buttons := row("row");
	buttons.semantic_size = .[ui.pct(1), ui.children()];
	{ ui.parent(buttons); defer ui.pop_parent();
		if bottles.readers label(tprint(Lp("% reader", "% readers", bottles.readers.count), bottles.readers.count), .Normal, 14, T("--text-muted"), 18);
		filler(.X);
		if adm_button("cancel", L("Cancel"), .Secondary) bottle_close();
		spacer(.X, 8);
		if adm_button("send", L("Bottle It"), .Primary, enabled = bottles.dest != 0 && bottles.readers.count > 0) send = true;
	}
	unpad();
	spacer(.Y, PAD);
	if send && bottles.msg bottle_send();
}
