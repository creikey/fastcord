// Undo, not confirm (fastcord-only, traffic/CLIENT_RULES.md "Undo"). A destructive action shows its
// result at once and its write waits UNDO_S behind the Undo toast (or Ctrl+Z / Cmd+Z when no text
// field takes it); then the request goes out as the official client sends it, only later. Undoing
// sends nothing. Pending writes go at once when their client is released (quit, log out, a hosted
// server dropped) or its gateway drops, so nothing is lost and nothing waits on a stale store.
//
// Each action is two procedures over an Undo: send (the request) and revert (puts the screen back;
// null when the held entry itself is what hides the change, see undo_held).

UNDO_S :: 5.0;

Undo :: struct {
	text: string; // the toast's line (heap); "" holds quietly, with no toast (a reaction)
	client: *dc.Client; // null offline (fixtures): nothing is sent
	until: float64; // platform.time_now()
	send: (u: *Undo);
	revert: (u: *Undo);
	a, b, c: dc.Snowflake; // what it acts on
	s, t: string; // heap, freed with it
	n: s64;
}

undos: [..]*Undo;

// Holds an action. The caller has already changed what the screen shows (or relies on undo_held).
undo_push :: (text: string, send: (u: *Undo), revert: (u: *Undo) = null, a: dc.Snowflake = 0, b: dc.Snowflake = 0, c: dc.Snowflake = 0, s := "", t := "", n := 0) -> *Undo {
	app.net_actions += 1;
	u := New(Undo);
	u.* = .{text = copy_string(text), client = app.client, until = platform.time_now() + UNDO_S, send = send, revert = revert, a = a, b = b, c = c, s = copy_string(s), t = copy_string(t), n = n};
	array_add(*undos, u);
	request_wake(u.until + 0.01);
	return u;
}

// The held action of this kind on a (and b, when given), if any.
undo_held :: (send: (u: *Undo), a: dc.Snowflake, b: dc.Snowflake = 0) -> *Undo {
	for undos if it.send == send && it.a == a && (b == 0 || it.b == b) return it;
	return null;
}

// Drops a held action without sending it, putting the screen back.
undo_cancel :: (u: *Undo) {
	if u.revert u.revert(u);
	undo_drop(u);
}

// Sends every held action now (all of them, or one client's: before it is released).
undo_flush :: (client: *dc.Client = null) {
	i := 0;
	while i < undos.count {
		u := undos[i];
		if client && u.client != client { i += 1; continue; }
		array_ordered_remove_by_index(*undos, i);
		undo_send(u);
	}
}

// Once per frame: actions past their time, or whose gateway dropped, go out.
undo_frame :: () {
	now := platform.time_now();
	i := 0;
	while i < undos.count {
		u := undos[i];
		if now < u.until && !(u.client && u.client.store.connection == .Disconnected) { request_wake(u.until + 0.01); i += 1; continue; }
		array_ordered_remove_by_index(*undos, i);
		undo_send(u);
	}
}

// The toast for the newest held action: its line and Undo. Ctrl+Z / Cmd+Z that no field took undoes it.
undo_toast :: () {
	u: *Undo;
	for < undos if it.text { u = it; break; }
	if !u return;
	shown := 0;
	for undos if it.text shown += 1;
	t := row("undotoast", .Draw_Background | .Floating_X | .Floating_Y | .Overlay | .Clickable);
	t.semantic_size = .[ui.children(), ui.px(40)];
	t.style.bg = T("--background-surface-highest");
	t.style.radius = all4(8);
	t.style.shadow_color = .{0, 0, 0, 0.24};
	t.style.shadow_blur = 8;
	t.flags |= .Draw_Shadow;
	w := t.rect.x1 - t.rect.x0;
	t.fixed_pos = .{(app.ui.window.x - w) / 2, app.ui.window.y - 40 - 96};
	ui.signal(t);
	undo := false;
	{ ui.parent(t); defer ui.pop_parent();
		spacer(.X, 16);
		line := u.text;
		if shown > 1 line = tprint("% (% more)", u.text, shown - 1);
		label(line, .Medium, 14, T("--text-default"), 18);
		spacer(.X, 16);
		b := ui.box("Undo##u", .Clickable | .Draw_Text | .Hot_Animation);
		b.semantic_size = .[ui.text_size(8), ui.px(40)];
		b.text = "Undo";
		b.style.font = F(.Semibold);
		b.style.font_size = 14;
		sig := ui.signal(b);
		b.style.text_color = ifx sig.hovering then T("--text-link") else T("--text-brand");
		if sig.clicked undo = true;
		spacer(.X, 8);
	}
	for * e: app.ui.events {
		if e.consumed || e.kind != .Key_Down || e.key != .Z || e.mods != PRIMARY_MOD continue;
		e.consumed = true;
		undo = true;
	}
	if undo undo_cancel(u);
}

#scope_file

undo_send :: (u: *Undo) {
	u.send(u);
	undo_free(u);
}

undo_drop :: (u: *Undo) {
	array_ordered_remove_by_value(*undos, u);
	undo_free(u);
}

undo_free :: (u: *Undo) {
	free(u.text);
	free(u.s);
	free(u.t);
	free(u);
}
