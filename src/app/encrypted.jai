// Encrypted DMs in the UI (TODO.md E2E 2-3). The `e2e` module does the crypto on the database thread;
// this file is its carrier for Discord's DMs and hosted servers' (serve's `dms.jai`), which both move
// `fc-` text in a 1:1 DM's messages: it asks it to open the packets a DM shows, and sends what it
// encrypts. The carrier is "discord" or "fc:" plus the hosted server's ID, a conversation is the DM's
// channel ID and the parties are user IDs, all as decimal text, and a delivery is a message ID. Hosted
// DMs are always encrypted: serve takes nothing else. The UI never waits: a message shows "Encrypted
// message" until its request comes back.

Shown :: struct {
	result: e2e.Result;
	content: e2e.Content;
	text: string;
	silent: bool; // Sent with @silent, said inside the packet.
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
	peer_root: [32]u8;
	verified: bool;
	key_changed: bool;
	hello_asked: bool; // A hosted DM sent its Hello by itself.
}

// A hosted server keeps each member's prekey bundle (serve's `e2e_bundle`), a Hello any of their DMs may
// answer, so a DM starts with a message even while its other member is offline. It's published at each
// login, again once one was answered (its prekeys go a day later), and every BUNDLE_S at the latest
// (unanswered prekeys go after a week).
Bundled :: struct { client: *dc.Client; at: float64; }
BUNDLE_S :: 3 * 24 * 3600.0;

Encrypted_State :: struct {
	shown: Table(dc.Snowflake, Shown); // By message ID; a sent message is first keyed by its nonce.
	channels: Table(dc.Snowflake, Encrypted_Channel);
	inflight: [..]*e2e.Request;
	generation: int; // Bumped when a session appears, so messages that were waiting for it retry.
	outbox_asked: [..]*dc.Client; // Each connection's outbox is sent once it's ready.
	bundled: [..]Bundled; // Hosted connections that published a prekey bundle, and when.
	told_set_aside: bool;
}
ee: Encrypted_State;

encrypted_frame :: () {
	if !e2e_db return;
	if !ee.told_set_aside && atomic_load(*e2e_db.set_aside) {
		ee.told_set_aside = true;
		toast_show(L("This device's encryption keys couldn't be unlocked, so earlier encrypted DMs can't be opened here."), false);
	}
	for c: connections() if c.store.ready && !array_find(ee.outbox_asked, c) {
		array_add(*ee.outbox_asked, c);
		e2e_submit(e2e.request(.Outbox, .{carrier = carrier_name(c)}));
	}
	for ee.bundled if !array_find(connections(), it.client) || platform.time_now() - it.at > BUNDLE_S remove it;
	if identity_ready() for c: connections() if c.cfg.hosted.host && c.store.ready {
		published := false;
		for ee.bundled if it.client == c published = true;
		if published continue;
		array_add(*ee.bundled, .{c, platform.time_now()});
		r := e2e.request(.Bundle, .{carrier = carrier_name(c), me = tprint("%", c.store.me), limit = fc_text.MAX_PACKET});
		r.me = my_identity();
		e2e_submit(r);
	}
	// Requests finish in submit order, so taking them from the front keeps sends in order.
	while ee.inflight.count && e2e.is_done(ee.inflight[0]) {
		r := ee.inflight[0];
		array_ordered_remove_by_index(*ee.inflight, 0);
		defer e2e.free_request(r);
		if r.failed { log_error("e2e: %", e2e_db.error); continue; }
		ch := find_or_add(*ee.channels, dc.parse_snowflake(r.conv.id));
		if r.op == {
			case .Load;
				ch.encrypted, ch.has_session, ch.loaded, ch.pending = r.encrypted, r.has_session, true, false;
				ch.has_peer, ch.peer_root, ch.verified, ch.key_changed = r.has_peer, r.peer_root, r.verified, r.key_changed;
			case .Receive;
				sh := find_or_add(*ee.shown, dc.parse_snowflake(r.delivery));
				free(sh.text);
				sh.* = .{result = r.result, content = r.content, text = copy_string(r.out_text), silent = r.silent, accepted = r.accepted, key_changed = r.key_changed, generation = ee.generation};
				if r.result == .Ok && r.content == .Accept && r.from != r.conv.me {
					ee.generation += 1;
					ch.encrypted, ch.has_session, ch.loaded = true, true, false; // Reload for the peer's root.
					for ee.bundled if carrier_name(it.client) == r.conv.carrier remove it; // maybe ours was answered: publish another
				}
				// On a hosted server every DM is encrypted, so a peer's Hello is answered without asking.
				if r.result == .Hello && !r.accepted && r.from != r.conv.me && begins_with(r.conv.carrier, HOSTED) && identity_ready() {
					sh.accepted = true;
					q := e2e.request(.Accept, .{r.conv.carrier, r.conv.id, r.conv.me, r.from, r.conv.limit}, packet = r.packet);
					q.me = my_identity();
					e2e_submit(q);
				}
			case .Hello;
				if r.result != .Ok { toast_show(L("Couldn't turn on encryption."), false); continue; }
				ch.encrypted = true;
				send_packet(r, .Hello, "");
			case .Accept;
				if r.result != .Ok { toast_show(L("Couldn't accept encryption."), false); continue; }
				ee.generation += 1;
				ch.encrypted, ch.has_session, ch.loaded = true, true, false;
				send_packet(r, .Ok, "", .Accept);
			case .Send;
				if r.result != .Ok { toast_show(L("Couldn't encrypt the message."), false); continue; }
				send_packet(r, .Ok, r.text);
			case .Search;
				search_add_decrypted(r); // view_search.jai
			case .Bundle;
				c := carrier_client(r.conv.carrier);
				if c && r.result == .Ok dc.e2e_bundle_call(c, "PUT", "/users/@me/e2e-bundle", tprint("{\"bundle\": \"%\"}", fc_text.encode(xx r.packet,, temp)));
			case .Outbox;
				// Packets saved before a crash, never handed to their carrier: their keys are spent, so send them now.
				c := carrier_client(r.conv.carrier);
				for r.outbox if c && it.carrier == r.conv.carrier {
					dc.send_message(c, dc.parse_snowflake(it.conversation), carrier_text(it.carrier, it.packet));
					e2e_submit(e2e.request(.Sent, packet = it.packet));
				}
		}
	}
}

// encrypted_packet: an `fc-` message in a Discord 1:1 DM, whose raw text must never be shown, copied
// or edited.
encrypted_packet :: (channel_id: dc.Snowflake, content: string) -> bool {
	return begins_with(packet_text(content), fc_text.PREFIX) && encrypted_dm(dc.channel_get(store(), channel_id));
}

// A Hello on Discord starts with HELLO_NOTE, so someone on the official client sees what the code under it
// is. It goes only with a Hello, which is sent only when someone turns encryption on.
HELLO_NOTE :: "Encryption request from fastcord, a Discord client (creikey.com/fastcord). Only fastcord can read the code below.\n";

// packet_text is a message's `fc-` text, without a Hello's note.
packet_text :: (content: string) -> string { return ifx begins_with(content, HELLO_NOTE) then advance(content, HELLO_NOTE.count) else content; }

// e2e_mark: in a 1:1 DM that has used encryption, whether a message was encrypted, so a plain one
// sent mid-conversation (by Discord, the peer, or while encryption was off) never reads as private.
E2E_Mark :: enum u8 { None; Encrypted; Plain; }
e2e_mark :: (m: *dc.Message) -> E2E_Mark {
	ch := dc.channel_get(store(), m.channel_id);
	if !encrypted_dm(ch) return .None;
	if encrypted_packet(m.channel_id, m.content) && !m.forwarded return .Encrypted;
	e := encrypted_channel(ch.id);
	return ifx e.encrypted || e.has_session then .Plain else .None;
}

// e2e_mark_icon draws a message's mark as a small icon, with what it means on hover.
e2e_mark_icon :: (mark: E2E_Mark, size: float32) {
	if mark == .None return;
	enc := mark == .Encrypted;
	ic := icon("e2e", ifx enc then "lock" else "warning", size, T(ifx enc then "--text-feedback-positive" else "--text-feedback-warning"), .Clickable);
	if ui.signal(ic).hovering tooltip_below(ifx enc then L("End-to-end encrypted") else L("Not encrypted: Discord can read this message"), ic.rect);
}

// encrypted_open asks once for a packet's plaintext (again after a session it waited for appears) and
// returns what is known so far: null or pending until the request comes back, or for good with no identity.
encrypted_open :: (id: dc.Snowflake, channel_id: dc.Snowflake, packet: string, author: dc.Snowflake) -> *Shown {
	sh := table_find_pointer(*ee.shown, id);
	retry := sh && sh.result == .No_Session && sh.generation != ee.generation && !sh.pending;
	if (!sh || retry) && e2e_db && identity_ready() {
		sh = find_or_add(*ee.shown, id);
		bytes, ok := fc_text.decode(packet_text(packet));
		if !ok { free(sh.text); sh.* = .{result = .Undecryptable}; return sh; }
		sh.pending = true;
		r := e2e.request(.Receive, conversation(channel_id), packet = xx bytes);
		r.me, r.from, r.delivery = my_identity(), sprint("%", author), sprint("%", id);
		e2e_submit(r);
	}
	return sh;
}

// encrypted_silent: an opened packet whose sender asked for no sound or notification, whatever the
// carrier's flags say.
encrypted_silent :: (id: dc.Snowflake) -> bool {
	sh := table_find_pointer(*ee.shown, id);
	return sh && !sh.pending && sh.result == .Ok && sh.silent;
}

// shown_text is a message's content as drawn outside the message list (previews, notifications, copies).
shown_text :: (id: dc.Snowflake, channel_id: dc.Snowflake, content: string) -> string {
	if !encrypted_packet(channel_id, content) return content;
	sh := table_find_pointer(*ee.shown, id);
	if sh && !sh.pending && sh.result == .Ok && sh.content == .Text return sh.text;
	return "Encrypted message";
}

encrypted_dm :: (ch: *dc.Channel) -> bool { return ch && ch.kind == .DM && ch.recipient_ids.count == 1; }

// encrypting: what the composer sends in this channel goes encrypted. A hosted DM always does, and sends
// its Hello the first time it's shown.
encrypting :: (ch: *dc.Channel) -> bool {
	if !encrypted_dm(ch) return false;
	if !on_hosted() return encrypted_channel(ch.id).encrypted;
	e := encrypted_channel(ch.id);
	if e.loaded && !e.encrypted && !e.has_session && !e.hello_asked && identity_ready() && e2e_db && ch.recipient_ids.count {
		// The peer's bundle if serve has one (encrypted_bundle_receive), else a Hello for them to answer.
		find_or_add(*ee.channels, ch.id).hello_asked = true;
		dc.e2e_bundle_call(app.client, "GET", tprint("/users/%/e2e-bundle", ch.recipient_ids[0]), tag = ch.id);
	}
	return true;
}

// encrypted_channel loads the DM's encryption state once; until then it reports encryption off.
encrypted_channel :: (id: dc.Snowflake) -> Encrypted_Channel {
	ch := find_or_add(*ee.channels, id);
	if !ch.loaded && !ch.pending && e2e_db {
		ch.pending = true;
		e2e_submit(e2e.request(.Load, conversation(id)));
	}
	return ch.*;
}

// The header's lock: turns encryption on (sending a Hello the first time) or off.
encrypted_toggle :: (dm: *dc.Channel) {
	if !net_action() || on_hosted() return;
	ch := encrypted_channel(dm.id);
	if !ch.loaded || !identity_ready() return;
	if ch.encrypted || ch.has_session {
		r := e2e.request(.Set_Encrypted, conversation(dm.id));
		r.encrypted = !ch.encrypted;
		find_or_add(*ee.channels, dm.id).encrypted = r.encrypted;
		e2e_submit(r);
		return;
	}
	send_hello(dm.id);
}

// encrypted_bundle_receive answers the peer's bundle a hosted DM asked for, which starts the session at once,
// or sends a Hello when they have none.
encrypted_bundle_receive :: (r: *dc.Feature_Result) {
	if !r.tag return; // a published one
	bundle: []u8;
	ok := false;
	if r.ok bundle, ok = fc_text.decode(dc.fstr(dc.vmap(r.body), "bundle"));
	if !ok { send_hello(r.tag); return; }
	q := e2e.request(.Accept, conversation(r.tag), packet = xx bundle);
	q.me = my_identity();
	e2e_submit(q);
}

// send_hello starts a new session in a DM: the first time, or after this device lost the old one.
send_hello :: (dm_id: dc.Snowflake) {
	find_or_add(*ee.channels, dm_id).hello_asked = true;
	r := e2e.request(.Hello, conversation(dm_id));
	r.me = my_identity();
	e2e_submit(r);
}

// encrypted_send takes over the composer's send in an encrypted DM. It returns false to keep the text,
// e.g. while the peer hasn't accepted yet.
encrypted_send :: (dm: *dc.Channel, text: string, has_attachments: bool, silent: bool) -> bool {
	ch := encrypted_channel(dm.id);
	if !ch.has_session {
		toast_show(tprint(ifx on_hosted() then L("Setting up encryption: % needs to open fastcord once.") else L("% hasn't accepted encryption yet."), dm_name(dm)), false);
		return false;
	}
	if has_attachments { toast_show(L("Files can't be sent encrypted yet."), false); return false; }
	most := e2e.max_text(fc_text.MAX_PACKET);
	if text.count > most { toast_show(tprint(L("Encrypted messages are limited to % bytes for now."), most), false); return false; }
	if !identity_ready() return false;
	r := e2e.request(.Send, conversation(dm.id), text);
	r.me, r.silent = my_identity(), silent;
	e2e_submit(r);
	return true;
}

// encrypted_body draws an `fc-` message in a 1:1 DM, or returns its plaintext for message_body to draw.
// false leaves the raw text to message_body.
encrypted_body :: (m: *dc.Message) -> handled: bool, plaintext: string {
	if !begins_with(packet_text(m.content), fc_text.PREFIX) return false, "";
	if !encrypted_dm(dc.channel_get(store(), m.channel_id)) return false, "";
	sh := ifx m.pending then table_find_pointer(*ee.shown, m.id) else encrypted_open(m.id, m.channel_id, m.content, m.author_id);
	muted :: (text: string) { label(text, .Normal, chat_px(MSG_FONT), T("--text-muted"), chat_px(MSG_LINE_H)); }
	if !sh || sh.pending { muted(L("Encrypted message")); return true, ""; }
	mine := m.author_id == store().me;
	name := ifx mine then "You" else author_name(m);
	if sh.result == .Ok && sh.content == .Text return true, sh.text;
	if sh.result == .Ok { muted(tprint(L("% accepted encryption."), name)); return true, ""; }
	if sh.result == .Repeated { muted(L("Repeated encrypted message")); return true, ""; }
	if sh.result == .No_Session && !mine {
		// Its session isn't here: a new device, a reinstall, or a lost fastcord.db. A new Hello makes a new
		// one, which both sides then use; or the message's Init may just not have loaded yet.
		r := row("lost");
		r.semantic_size = .[ui.pct(1), ui.children()];
		r.cross_align = .Center;
		ui.parent(r); defer ui.pop_parent();
		muted(L("This device can't open this message."));
		if !encrypted_channel(m.channel_id).hello_asked && !on_hosted() {
			spacer(.X, 12);
			if adm_button("rekey", L("Send New Key"), .Secondary) && identity_ready() && net_action() send_hello(m.channel_id);
		}
		return true, "";
	}
	if sh.result != .Hello { muted(L("Encrypted message")); return true, ""; }
	if mine || sh.accepted { muted(tprint(L("% turned on encryption."), name)); return true, ""; }
	r := row("hello");
	r.semantic_size = .[ui.pct(1), ui.children()];
	r.cross_align = .Center;
	ui.parent(r); defer ui.pop_parent();
	if sh.key_changed {
		icon("warn", "warning", 16, T("--status-warning"));
		spacer(.X, 6);
		label(tprint(L("% wants to encrypt this DM with a new key. Compare safety numbers after accepting."), name), .Normal, MSG_FONT, T("--text-default"), MSG_LINE_H);
	} else {
		label(tprint(L("% wants to encrypt this DM."), name), .Normal, MSG_FONT, T("--text-default"), MSG_LINE_H);
	}
	spacer(.X, 12);
	if adm_button("accept", L("Accept"), .Primary) && identity_ready() && net_action() {
		hello, ok := fc_text.decode(packet_text(m.content));
		if ok {
			sh.accepted = true;
			q := e2e.request(.Accept, conversation(m.channel_id, m.author_id), packet = xx hello);
			q.me = my_identity();
			e2e_submit(q);
		}
	}
	return true, "";
}

// encrypted_search asks for a 1:1 DM's opened texts holding every word, for the search panel.
encrypted_search :: (ch: *dc.Channel, words: string) {
	if !encrypted_dm(ch) || !e2e_db || !trim(words) return;
	e2e_submit(e2e.request(.Search, conversation(ch.id), words));
}

// encrypted_verify marks the peer's current root verified or not; either one dismisses a key change.
encrypted_verify :: (dm_id: dc.Snowflake, verified: bool) {
	ch := find_or_add(*ee.channels, dm_id);
	if !ch.has_peer || !e2e_db return;
	r := e2e.request(.Set_Verified, conversation(dm_id));
	r.peer_root, r.verified = ch.peer_root, verified;
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
	label(L("Safety Number"), .Semibold, 12, T("--text-strong"), 16);
	if ch.verified {
		spacer(.X, 6);
		icon("ok", "checkmark-small-bold", 14, T("--text-feedback-positive"));
		label(L("Verified"), .Medium, 12, T("--text-feedback-positive"), 16);
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
	p := ui.box(tprint(L("Compare these with %, in person or on a call. If they match, no one can read this DM in between.##note"), dm_name(dm)), .Draw_Text | .Wrap_Text);
	p.semantic_size = .[ui.fill(), ui.text_size()];
	p.style.font = F(.Normal);
	p.style.font_size = 12;
	p.style.line_height = 16;
	p.style.text_color = T("--text-muted");
	spacer(.X, pad);
	ui.pop_parent();
	spacer(.Y, 8);
	line("sn_b", pad);
	if adm_button("verify", ifx ch.verified then L("Unverify") else L("Mark as Verified"), ifx ch.verified then .Secondary else .Primary) encrypted_verify(dm.id, !ch.verified);
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
		p := ui.box(tprint(L("%'s encryption key changed. Compare safety numbers before trusting new messages.##text"), dm_name(dm)), .Draw_Text | .Wrap_Text);
		p.semantic_size = .[ui.fill(), ui.text_size()];
		p.style.font = F(.Normal);
		p.style.font_size = 14;
		p.style.line_height = 18;
		p.style.text_color = T("--text-default");
		spacer(.X, 12);
		if adm_button("compare", L("Compare"), .Primary) app.view.hide_dm_profile = false;
		spacer(.X, 8);
		if adm_button("dismiss", L("Dismiss"), .Secondary) encrypted_verify(dm.id, false);
		spacer(.X, 12);
	}
	sep := ui.box("keysep", .Draw_Background);
	sep.semantic_size = .[ui.pct(1), ui.px(1)];
	sep.style.bg = T("--border-subtle");
}

#scope_file

// Carrier names, kept with every conversation in fastcord.db: Discord's, or a hosted server's by its ID.
DISCORD :: "discord";
HOSTED :: "fc:";

carrier_name :: (c: *dc.Client) -> string { return ifx c && c.cfg.hosted.host then tprint("%1%2", HOSTED, c.cfg.hosted.server_id) else DISCORD; }

// carrier_text is a packet as a message: `fc-` text, with the note before a Hello on Discord.
carrier_text :: (carrier: string, packet: string) -> string {
	text := fc_text.encode(xx packet,, temp);
	hello := packet.count >= 2 && packet[1] == xx e2e.Kind.Hello;
	return ifx hello && carrier == DISCORD then tprint("%1%2", HELLO_NOTE, text) else text;
}

carrier_client :: (name: string) -> *dc.Client {
	for connections() if carrier_name(it) == name return it;
	return null;
}

// conversation names a 1:1 DM on the selected connection to the e2e core; peer defaults to the DM's recipient.
conversation :: (channel_id: dc.Snowflake, peer: dc.Snowflake = 0) -> e2e.Conversation {
	s := store();
	ch := dc.channel_get(s, channel_id);
	if !peer && ch && ch.recipient_ids.count peer = ch.recipient_ids[0];
	return .{carrier_name(app.client), tprint("%", channel_id), tprint("%", s.me), tprint("%", peer), fc_text.MAX_PACKET};
}

identity_ready ::() -> bool { return atomic_load(*idk.done) != 0 && idk.list.count > 0; }

my_identity :: () -> e2e.Identity { return e2e.identity_of(idk.list[0]); }

e2e_submit :: (r: *e2e.Request) {
	array_add(*ee.inflight, r);
	e2e.submit(e2e_db, r);
}

// send_packet hands a committed packet to its carrier, shows its pending copy as what it holds, and drops
// it from the outbox.
send_packet :: (r: *e2e.Request, result: e2e.Result, text: string, content := e2e.Content.Text) {
	c := carrier_client(r.conv.carrier);
	if !c return; // The outbox sends it on the next start.
	// The carrier's own flag too, so its push stays quiet; it says nothing about the content.
	nonce := dc.send_message(c, dc.parse_snowflake(r.conv.id), carrier_text(r.conv.carrier, r.packet), .{flags = ifx r.silent then SUPPRESS_NOTIFICATIONS else 0});
	sh := find_or_add(*ee.shown, nonce);
	free(sh.text);
	sh.* = .{result = result, content = content, text = copy_string(text), silent = r.silent};
	e2e_submit(e2e.request(.Sent, packet = r.packet));
}
