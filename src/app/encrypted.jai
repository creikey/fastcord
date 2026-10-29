// Encrypted DMs in the UI (TODO.md E2E 2-3). The `e2e` module does the crypto on the database thread;
// this file asks it to open the `fc-` messages a 1:1 DM shows, and sends what it encrypts. The UI never
// waits: a message shows "Encrypted message" until its request comes back.

Shown :: struct {
	result: e2e.Result;
	content: e2e.Content;
	text: string;
	accepted: bool;
	key_changed: bool; // A Hello whose root isn't the one this peer had.
	pending: bool;
	generation: int; // ee.generation when a No_Session result came back.
}

Encrypted_Channel :: struct {
	encrypted: bool;
	has_session: bool;
	loaded: bool;
	pending: bool;
	has_peer: bool; // The peer's identity root, once a session exists.
	peer: dc.Snowflake;
	peer_root: [32]u8;
	verified: bool;
	key_changed: bool;
}

Encrypted_State :: struct {
	shown: Table(dc.Snowflake, Shown); // By message ID; a sent message is first keyed by its nonce.
	channels: Table(dc.Snowflake, Encrypted_Channel);
	inflight: [..]*e2e.Request;
	generation: int; // Bumped when a session appears, so messages that were waiting for it retry.
	outbox_asked: bool;
}
ee: Encrypted_State;

encrypted_frame :: () {
	if !e2e_db return;
	if !ee.outbox_asked && app.discord && app.discord.store.ready {
		ee.outbox_asked = true;
		e2e_submit(e2e.request(.Outbox));
	}
	// Requests finish in submit order, so taking them from the front keeps sends in order.
	while ee.inflight.count && e2e.is_done(ee.inflight[0]) {
		r := ee.inflight[0];
		array_ordered_remove_by_index(*ee.inflight, 0);
		defer e2e.free_request(r);
		if r.failed { log_error("e2e: %", e2e_db.error); continue; }
		ch := find_or_add(*ee.channels, r.channel);
		if r.op == {
			case .Load;
				ch.encrypted, ch.has_session, ch.loaded, ch.pending = r.encrypted, r.has_session, true, false;
				ch.has_peer, ch.peer, ch.peer_root, ch.verified, ch.key_changed = r.has_peer, r.peer, r.peer_root, r.verified, r.key_changed;
			case .Receive;
				sh := find_or_add(*ee.shown, r.message);
				free(sh.text);
				sh.* = .{result = r.result, content = r.content, text = copy_string(r.out_text), accepted = r.accepted, key_changed = r.key_changed, generation = ee.generation};
				if r.result == .Ok && r.content == .Accept && r.author != r.me_user {
					ee.generation += 1;
					ch.encrypted, ch.has_session, ch.loaded = true, true, false; // Reload for the peer's root.
				}
			case .Hello;
				if r.result != .Ok { toast_show("Couldn't turn on encryption.", false); continue; }
				ch.encrypted = true;
				send_packet(r, .Hello, "");
			case .Accept;
				if r.result != .Ok { toast_show("Couldn't accept encryption.", false); continue; }
				ee.generation += 1;
				ch.encrypted, ch.has_session, ch.loaded = true, true, false;
				send_packet(r, .Ok, "", .Accept);
			case .Send;
				if r.result != .Ok { toast_show("Couldn't encrypt the message.", false); continue; }
				send_packet(r, .Ok, r.text);
			case .Outbox;
				// Packets saved before a crash, never handed to Discord: their keys are spent, so send them now.
				for r.outbox if app.discord {
					dc.send_message(app.discord, it.channel, it.packet);
					e2e_submit(e2e.request(.Sent, it.channel, it.packet));
				}
		}
	}
}

// encrypted_packet: an `fc-` message in a Discord 1:1 DM, whose raw text must never be shown, copied
// or edited.
encrypted_packet :: (channel_id: dc.Snowflake, content: string) -> bool {
	if !begins_with(content, e2e.PREFIX) || !app.discord return false;
	ch := dc.channel_get(*app.discord.store, channel_id);
	return ch && ch.kind == .DM && ch.recipient_ids.count == 1;
}

// shown_text is a message's content as drawn outside the message list (previews, notifications, copies).
shown_text :: (id: dc.Snowflake, channel_id: dc.Snowflake, content: string) -> string {
	if !encrypted_packet(channel_id, content) return content;
	sh := table_find_pointer(*ee.shown, id);
	if sh && !sh.pending && sh.result == .Ok && sh.content == .Text return sh.text;
	return "Encrypted message";
}

encrypted_dm :: (ch: *dc.Channel) -> bool { return ch && ch.kind == .DM && ch.recipient_ids.count == 1 && app.client == app.discord; }

// encrypting: what the composer sends in this channel goes encrypted.
encrypting :: (ch: *dc.Channel) -> bool { return encrypted_dm(ch) && encrypted_channel(ch.id).encrypted; }

// encrypted_channel loads the DM's encryption state once; until then it reports encryption off.
encrypted_channel :: (id: dc.Snowflake) -> Encrypted_Channel {
	ch := find_or_add(*ee.channels, id);
	if !ch.loaded && !ch.pending && e2e_db {
		ch.pending = true;
		e2e_submit(e2e.request(.Load, id));
	}
	return ch.*;
}

// The header's lock: turns encryption on (sending a Hello the first time) or off.
encrypted_toggle :: (dm: *dc.Channel) {
	if !net_action() return;
	ch := encrypted_channel(dm.id);
	if !ch.loaded || !identity_ready() return;
	if ch.encrypted || ch.has_session {
		r := e2e.request(.Set_Encrypted, dm.id);
		r.encrypted = !ch.encrypted;
		find_or_add(*ee.channels, dm.id).encrypted = r.encrypted;
		e2e_submit(r);
		return;
	}
	r := e2e.request(.Hello, dm.id);
	r.me = my_identity();
	e2e_submit(r);
}

// encrypted_send takes over the composer's send in an encrypted DM. It returns false to keep the text,
// e.g. while the peer hasn't accepted yet.
encrypted_send :: (dm: *dc.Channel, text: string, has_attachments: bool) -> bool {
	ch := encrypted_channel(dm.id);
	if !ch.has_session { toast_show(tprint("% hasn't accepted encryption yet.", dm_name(dm)), false); return false; }
	if has_attachments { toast_show("Files can't be sent encrypted yet.", false); return false; }
	if text.count > e2e.MAX_TEXT_BYTES { toast_show(tprint("Encrypted messages are limited to % bytes for now.", e2e.MAX_TEXT_BYTES), false); return false; }
	if !identity_ready() return false;
	r := e2e.request(.Send, dm.id, text);
	r.me = my_identity();
	e2e_submit(r);
	return true;
}

// encrypted_body draws an `fc-` message in a 1:1 DM, or returns its plaintext for message_body to draw.
// false leaves the raw text to message_body.
encrypted_body :: (m: *dc.Message) -> handled: bool, plaintext: string {
	if !begins_with(m.content, e2e.PREFIX) return false, "";
	if !encrypted_dm(dc.channel_get(store(), m.channel_id)) return false, "";
	sh := table_find_pointer(*ee.shown, m.id);
	retry := sh && sh.result == .No_Session && sh.generation != ee.generation && !sh.pending;
	if (!sh || retry) && !m.pending && identity_ready() {
		sh = find_or_add(*ee.shown, m.id);
		sh.pending = true;
		r := e2e.request(.Receive, m.channel_id, m.content);
		r.me, r.me_user, r.author, r.message = my_identity(), store().me, m.author_id, m.id;
		e2e_submit(r);
	}
	muted :: (text: string) { label(text, .Normal, MSG_FONT, T("--text-muted"), MSG_LINE_H); }
	if !sh || sh.pending { muted("Encrypted message"); return true, ""; }
	mine := m.author_id == store().me;
	name := ifx mine then "You" else author_name(m);
	if sh.result == .Ok && sh.content == .Text return true, sh.text;
	if sh.result == .Ok { muted(tprint("% accepted encryption.", name)); return true, ""; }
	if sh.result == .Repeated { muted("Repeated encrypted message"); return true, ""; }
	if sh.result != .Hello { muted("Encrypted message"); return true, ""; }
	if mine || sh.accepted { muted(tprint("% turned on encryption.", name)); return true, ""; }
	r := row("hello");
	r.semantic_size = .[ui.pct(1), ui.children()];
	r.cross_align = .Center;
	ui.parent(r); defer ui.pop_parent();
	if sh.key_changed {
		icon("warn", "warning", 16, T("--status-warning"));
		spacer(.X, 6);
		label(tprint("% wants to encrypt this DM with a new key. Compare safety numbers after accepting.", name), .Normal, MSG_FONT, T("--text-default"), MSG_LINE_H);
	} else {
		label(tprint("% wants to encrypt this DM.", name), .Normal, MSG_FONT, T("--text-default"), MSG_LINE_H);
	}
	spacer(.X, 12);
	if adm_button("accept", "Accept", .Primary) && identity_ready() && net_action() {
		sh.accepted = true;
		q := e2e.request(.Accept, m.channel_id, m.content);
		q.me, q.me_user, q.peer = my_identity(), store().me, m.author_id;
		e2e_submit(q);
	}
	return true, "";
}

// encrypted_verify marks the peer's current root verified or not; either one dismisses a key change.
encrypted_verify :: (dm_id: dc.Snowflake, verified: bool) {
	ch := find_or_add(*ee.channels, dm_id);
	if !ch.has_peer || !e2e_db return;
	r := e2e.request(.Set_Verified, dm_id);
	r.peer, r.peer_root, r.verified = ch.peer, ch.peer_root, verified;
	ch.verified, ch.key_changed = verified, false;
	e2e_submit(r);
}

// encrypted_profile is the safety number section of a 1:1 DM's profile panel (E2E 4): 60 digits both
// people should see alike, compared in person or on a call, then marked Verified.
encrypted_profile :: (dm: *dc.Channel, pad: float32) {
	if !encrypted_dm(dm) || !identity_ready() return;
	ch := encrypted_channel(dm.id);
	if !ch.has_peer return;
	line ::(id: string, pad: float32) -> *ui.Box {
		r := row(id);
		r.semantic_size = .[ui.pct(1), ui.children()];
		r.cross_align = .Center;
		ui.push_parent(r);
		spacer(.X, pad);
		return r;
	}
	spacer(.Y, 20);
	line("sn_h", pad);
	label("Safety Number", .Semibold, 12, T("--text-strong"), 16);
	if ch.verified {
		spacer(.X, 6);
		icon("ok", "checkmark-small-bold", 14, T("--text-feedback-positive"));
		label("Verified", .Medium, 12, T("--text-feedback-positive"), 16);
	}
	ui.pop_parent();
	spacer(.Y, 6);
	digits := e2e.safety_number(idk.list[0].root, ch.peer_root);
	for l: 0..2 {
		line(tprint("sn%", l), pad);
		b := label(tprint("% % % %", to_string(*digits[l * 20], 5), to_string(*digits[l * 20 + 5], 5), to_string(*digits[l * 20 + 10], 5), to_string(*digits[l * 20 + 15], 5)),
			.Mono, 14, T("--text-default"), 20);
		b.flags |= .Selectable_Text;
		ui.pop_parent();
	}
	spacer(.Y, 6);
	line("sn_note", pad);
	p := ui.box(tprint("Compare these with %, in person or on a call. If they match, no one can read this DM in between.##note", dm_name(dm)), .Draw_Text | .Wrap_Text);
	p.semantic_size = .[ui.fill(), ui.text_size()];
	p.style.font = F(.Normal);
	p.style.font_size = 12;
	p.style.line_height = 16;
	p.style.text_color = T("--text-muted");
	spacer(.X, pad);
	ui.pop_parent();
	spacer(.Y, 8);
	line("sn_b", pad);
	if adm_button("verify", ifx ch.verified then "Unverify" else "Mark as Verified", ifx ch.verified then .Secondary else .Primary) encrypted_verify(dm.id, !ch.verified);
	ui.pop_parent();
}

// encrypted_warning sits atop the composer while the peer's identity root is new and unconfirmed.
encrypted_warning :: (dm: *dc.Channel) {
	if !encrypted_dm(dm) return;
	ch := encrypted_channel(dm.id);
	if !ch.key_changed return;
	bar := row("keychanged");
	bar.semantic_size = .[ui.pct(1), ui.px(54)];
	bar.cross_align = .Center;
	{ ui.parent(bar); defer ui.pop_parent();
		spacer(.X, 16);
		icon("warn", "warning", 18, T("--status-warning"));
		spacer(.X, 8);
		p := ui.box(tprint("%'s encryption key changed. Compare safety numbers before trusting new messages.##text", dm_name(dm)), .Draw_Text | .Wrap_Text);
		p.semantic_size = .[ui.fill(), ui.text_size()];
		p.style.font = F(.Normal);
		p.style.font_size = 14;
		p.style.line_height = 18;
		p.style.text_color = T("--text-default");
		spacer(.X, 12);
		if adm_button("compare", "Compare", .Primary) app.view.hide_dm_profile = false;
		spacer(.X, 8);
		if adm_button("dismiss", "Dismiss", .Secondary) encrypted_verify(dm.id, false);
		spacer(.X, 12);
	}
	sep := ui.box("keysep", .Draw_Background);
	sep.semantic_size = .[ui.pct(1), ui.px(1)];
	sep.style.bg = T("--border-subtle");
}

#scope_file

identity_ready ::() -> bool { return atomic_load(*idk.done) != 0 && idk.list.count > 0; }

my_identity :: () -> e2e.Identity { return e2e.identity_of(idk.list[0]); }

e2e_submit :: (r: *e2e.Request) {
	array_add(*ee.inflight, r);
	e2e.submit(e2e_db, r);
}

// send_packet hands a committed packet to Discord, shows its pending copy as what it holds, and drops
// it from the outbox.
send_packet :: (r: *e2e.Request, result: e2e.Result, text: string, content := e2e.Content.Text) {
	if !app.discord return; // The outbox sends it on the next start.
	nonce := dc.send_message(app.discord, r.channel, r.packet);
	sh := find_or_add(*ee.shown, nonce);
	free(sh.text);
	sh.* = .{result = result, content = content, text = copy_string(text)};
	e2e_submit(e2e.request(.Sent, r.channel, r.packet));
}
