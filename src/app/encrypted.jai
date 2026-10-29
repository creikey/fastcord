// Encrypted DMs in the UI (TODO.md E2E 2-3, 7). The `e2e` module does the crypto on the database thread;
// this file is its carrier for Discord's DMs and hosted servers' (serve's `dms.jai`), which both move
// `fc-` text in a 1:1 DM's messages: it asks it to open the packets a DM shows, and sends what it
// encrypts. The carrier is "discord" or "fc:" plus the hosted server's ID, a conversation is the DM's
// channel ID and the parties are user IDs, all as decimal text, and a delivery is a message ID. Hosted
// DMs are always encrypted: serve takes nothing else. The UI never waits: a message shows "Encrypted
// message" until its request comes back.
//
// Inside the packet (E2E 7): a reply names its message; files upload as ciphertext attachments named
// ENCRYPTED_NAME, in the packet's order, and open into `blobs` under an E2E_URL key that is never fetched;
// an edit or delete edits the message itself into a new packet (an edit too long for a message's text goes
// as a hidden message of its own, which the receiving side applies to the one it names); a reaction is a packet of its own, hidden
// from the list and drawn on the message it names. A sticker goes as its ID, a GIF as a file the sender
// fetched, and a forward as a new message re-encrypted for its destination.

Shown :: struct {
	result: e2e.Result;
	content: e2e.Content;
	text: string;
	silent: bool; // Sent with @silent, said inside the packet.
	accepted: bool;
	sent: bool; // Our pending copy, by its nonce: the message that lands must still be opened, to claim it.
	key_changed: bool; // A Hello whose root isn't the one this peer had.
	pending: bool;
	generation: int; // ee.generation when a No_Session result came back.
	kind: u8; // The packet's (e2e.Kind), once opened or not.
	edited: string; // The message's edited_timestamp when it was opened: an edit brings a new packet.
	detached: bool; // An Edit too long for its message's place, sent as a hidden message of its own.
	stale: bool; // A detached edit of this message came: open it again for its latest text.
	reply: dc.Snowflake;
	files: [..]e2e.File;
	packet: string; // A Hello's, for Accept: its text may only name an attachment.
	stickers: [..]dc.Snowflake;
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
	peers: [..]dc.Snowflake; // Who we have a session with: in a group, who gets our sender key.
	asked: [..]dc.Snowflake; // A hosted group: whose bundles were asked for (this run).
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
	reactions: Table(dc.Snowflake, [..]E2E_Reaction); // By the message they're on.
	attachments: Table(*e2e.Request, []dc.Draft_Attachment); // A Send's uploads, until its packet goes.
	opening: [..]*Open_File;
	gifs: [..]Gif_Fetch; // GIFs being fetched to go as encrypted files
}

Gif_Fetch :: struct { channel: dc.Snowflake; url: string; width, height: int; mime: string; }

// The latest encrypted reaction of one person with one emoji on a message: the newest delivery wins.
E2E_Reaction :: struct { user: dc.Snowflake; emoji: string; at: dc.Snowflake; on: bool; }

ENCRYPTED_NAME :: "encrypted.bin"; // What a sealed file uploads as, whatever it is.
E2E_URL :: "e2e:"; // An opened file's key in blobs and images, from its digest: never fetched.

// Open_File decrypts a downloaded file on the database thread, off the UI's; or, with message set, takes
// a packet too large for a message from its attachment once it matches digest.
Open_File :: struct {
	#as using job: e2e.Job;
	key: string; // E2E_URL
	url: string; // where the ciphertext is
	file: e2e.File;
	ct, out: []u8;
	ok, started: bool;
	message, channel, author: dc.Snowflake;
	digest: [32]u8;
}
ee: Encrypted_State;

encrypted_frame :: () {
	if !e2e_db return;
	encrypted_files_frame();
	for g: ee.gifs {
		b := table_find_pointer(*blobs, g.url);
		if b && b.state == .Loading continue;
		dm := dc.channel_get(store(), g.channel);
		if b && b.state == .Ready && app.client && dm {
			f := e2e.File.{width = g.width, height = g.height, name = tprint("tenor.%", slice(g.mime, 6, g.mime.count - 6)), mime = g.mime};
			ct := e2e.seal_file(b.data, *f);
			draft := dc.upload_draft(app.client, g.channel, ENCRYPTED_NAME, "application/octet-stream", ct, "gif_picker");
			encrypted_post(dm, "", false, files = .[f], atts = .[.{handle = draft, filename = ENCRYPTED_NAME}], cts = .[ct]);
			array_free(ct);
		} else {
			toast_show(L("Couldn't get that GIF."), false);
		}
		free(g.url);
		remove g;
	}
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
		r := e2e.request(.Bundle, .{carrier = carrier_name(c), me = tprint("%", c.store.me), limit = e2e.MAX_PACKET});
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
				ch.peers.count = 0;
				for r.peers array_add(*ch.peers, dc.parse_snowflake(it));
			case .Receive;
				id := dc.parse_snowflake(r.delivery);
				sh := find_or_add(*ee.shown, id);
				edited := sh.edited;
				sh.edited = "";
				shown_free(sh);
				sh.* = .{result = r.result, content = r.content, text = copy_string(r.out_text), silent = r.silent, accepted = r.accepted, key_changed = r.key_changed, generation = ee.generation,
					edited = edited, reply = dc.parse_snowflake(r.reply), files = files_copy(r.files), packet = ifx r.result == .Hello then copy_string(r.packet),
					stickers = stickers_of(r.stickers), kind = ifx r.packet.count > 1 then r.packet[1]};
				if r.result == .Ok && r.content == .Sender_Key && r.from != r.conv.me ee.generation += 1; // a group's messages waiting for this chain retry
				if r.result == .Ok && r.content == .Edit && r.target != r.delivery {
					// Detached: hidden, and its message, already open, opens again with the latest edit. One still
					// opening was asked after this one, so it gets it.
					sh.detached = true;
					t := table_find_pointer(*ee.shown, dc.parse_snowflake(r.target));
					if t && !t.pending t.stale = true;
				}
				if r.result == .Ok && (r.content == .React || r.content == .Unreact) reaction_note(dc.parse_snowflake(r.target), dc.parse_snowflake(r.from), r.out_text, id, r.content == .React);
				if r.result == .Ok && r.content == .Accept && r.from != r.conv.me {
					ee.generation += 1;
					ch.encrypted, ch.has_session, ch.loaded = true, true, false; // Reload for the peer's root.
					for ee.bundled if carrier_name(it.client) == r.conv.carrier remove it; // maybe ours was answered: publish another
				}
				// On a hosted server every DM is encrypted, so a peer's Hello is answered without asking; so is a
				// member's in a group we encrypt (E2E 8), as each pair needs a session. A hosted group member
				// we already have one with started theirs from our bundle meanwhile: no second.
				dm := dc.channel_get(store(), dc.parse_snowflake(r.conv.id));
				hosted_group := begins_with(r.conv.carrier, HOSTED) && dm && dm.kind == .Group_DM;
				auto := ifx hosted_group then !array_find(ch.peers, dc.parse_snowflake(r.from)) else begins_with(r.conv.carrier, HOSTED) || (dm && dm.kind == .Group_DM && ch.encrypted);
				if r.result == .Hello && !r.accepted && r.from != r.conv.me && auto && identity_ready() {
					sh.accepted = true;
					q := e2e.request(.Accept, .{r.conv.carrier, r.conv.id, r.conv.me, r.from, fc_text.MAX_PACKET}, packet = r.packet);
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
				// In a group on Discord the others need a session with us too: our own Hello, once. On a hosted
				// server each answers our bundle instead (encrypting).
				dm := dc.channel_get(store(), dc.parse_snowflake(r.conv.id));
				if dm && dm.kind == .Group_DM && !ch.hello_asked && !begins_with(r.conv.carrier, HOSTED) send_hello(dm.id);
			case .Send;
				if r.result != .Ok {
					toast_show(ifx r.result == .Too_Long then L("That's too long to send encrypted.") else L("Couldn't encrypt the message."), false);
					_, atts := table_remove(*ee.attachments, r);
					free(atts.data);
					continue;
				}
				send_packet(r, .Ok, r.text, r.content);
			case .Search;
				search_add_decrypted(r); // view_search.jai
			case .Bundle;
				c := carrier_client(r.conv.carrier);
				if c && r.result == .Ok dc.e2e_bundle_call(c, "PUT", "/users/@me/e2e-bundle", tprint("{\"bundle\": \"%\"}", fc_text.encode(xx r.packet,, temp)));
			case .Outbox;
				// Packets saved before a crash, never handed to their carrier: their keys are spent, so send them now.
				c := carrier_client(r.conv.carrier);
				for r.outbox if c && it.carrier == r.conv.carrier {
					channel, text := dc.parse_snowflake(it.conversation), carrier_text(it.carrier, it.packet);
					atts := NewArray(it.files.count, dc.Draft_Attachment,, temp);
					for f: it.files atts[it_index] = .{handle = dc.upload_draft(c, channel, ENCRYPTED_NAME, "application/octet-stream", xx f), filename = ENCRYPTED_NAME};
					if it.replaces dc.edit_message(c, channel, dc.parse_snowflake(it.replaces), text);
					else post_packet(c, channel, it.carrier, it.packet, it.silent, atts);
					e2e_submit(e2e.request(.Sent, packet = it.packet));
				}
		}
	}
}

// encrypted_files_frame moves each file being opened along: its ciphertext downloaded, then decrypted on
// the database thread, then shown from blobs.
encrypted_files_frame :: () {
	for o: ee.opening {
		if !o.started {
			b := table_find_pointer(*blobs, o.url);
			if b && b.state == .Loading continue;
			o.started = true;
			if o.message {
				// An attached packet: opened like any other once it's the one the text names.
				sh := find_or_add(*ee.shown, o.message);
				packet := ifx b && b.state == .Ready && b.data.count <= e2e.MAX_PACKET && e2e.same(crypto.blake3(b.data), o.digest) then cast(string) b.data;
				if packet {
					r := e2e.request(.Receive, conversation(o.channel), packet = packet);
					r.me, r.from, r.delivery, r.order = my_identity(), sprint("%", o.author), sprint("%", o.message), xx o.message;
					e2e_submit(r);
				} else {
					sh.pending = false;
					sh.result = .Undecryptable;
				}
				free(o.url);
				free(o);
				remove o;
				continue;
			}
			if b && b.state == .Ready {
				o.ct = b.data;
				b.data = .[];
				b.state = .Failed; // Taken: it's not fetched again for this message.
				o.run = (d: *e2e.Db, j: *e2e.Job) { f := cast(*Open_File) j; f.out, f.ok = e2e.open_file(f.file, f.ct); };
				e2e.submit(e2e_db, o);
				continue;
			}
		} else if !e2e.is_done(o) continue;
		ob := table_find_pointer(*blobs, o.key);
		if ob ob.data, ob.state = o.out, ifx o.ok then Image_State.Ready else .Failed;
		else array_free(o.out);
		array_free(o.ct);
		free(o.url);
		free(o.file.name); free(o.file.mime); free(o.file.description);
		free(o);
		remove o;
		app.ui.animating = true;
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

// encrypted_open asks once for a packet's plaintext (again after a session it waited for appears, or an
// edit brought another packet) and returns what is known so far: null or pending until the request comes
// back, or for good with no identity.
encrypted_open :: (id: dc.Snowflake, channel_id: dc.Snowflake, packet: string, author: dc.Snowflake, edited := "") -> *Shown {
	sh := table_find_pointer(*ee.shown, id);
	retry := sh && ((sh.result == .No_Session && sh.generation != ee.generation) || sh.edited != edited || sh.sent || sh.stale) && !sh.pending;
	if (!sh || retry) && e2e_db && identity_ready() {
		sh = find_or_add(*ee.shown, id);
		bytes, ok := fc_text.decode(packet_text(packet));
		free(sh.edited);
		sh.edited = copy_string(edited);
		hash, attached := fc_text.attached_hash(bytes);
		if attached {
			// The packet is the message's last attachment, of at most the largest packet: fetched, then checked.
			l := table_find_pointer(*store().messages, channel_id);
			i := ifx l then dc.message_index(l, id) else -1;
			m := ifx i >= 0 then *l.messages[i] else null;
			ok = m && m.attachments.count && peek(m.attachments).size <= e2e.MAX_PACKET;
			if ok {
				sh.pending = true;
				f := New(Open_File);
				f.url, f.digest, f.message, f.channel, f.author = copy_string(peek(m.attachments).url), hash, id, channel_id, author;
				array_add(*ee.opening, f);
				blob_get(f.url);
				return sh;
			}
		}
		if !ok { e := sh.edited; sh.edited = ""; shown_free(sh); sh.* = .{result = .Undecryptable, edited = e}; return sh; }
		sh.pending = true;
		r := e2e.request(.Receive, conversation(channel_id), packet = xx bytes);
		r.me, r.from, r.delivery, r.order = my_identity(), sprint("%", author), sprint("%", id), xx id;
		e2e_submit(r);
	}
	return sh;
}

// encrypted_silent: an opened packet whose sender asked for no sound or notification, whatever the
// carrier's flags say.
encrypted_silent :: (id: dc.Snowflake) -> bool {
	sh := table_find_pointer(*ee.shown, id);
	return sh && !sh.pending && sh.result == .Ok && (sh.silent || !is_text(sh.content) || sh.detached);
}

// encrypted_hidden: a packet that isn't a message of its own (a reaction, or a message deleted), so the
// list skips it.
encrypted_hidden :: (m: *dc.Message) -> bool {
	if !encrypted_packet(m.channel_id, m.content) return false;
	sh := table_find_pointer(*ee.shown, m.id);
	if !sh || sh.pending return false;
	if sh.result == .Ok return sh.content == .Delete || sh.content == .React || sh.content == .Unreact || sh.content == .Sender_Key || sh.detached;
	// In a group, the pairwise packets between two other members aren't ours to show.
	ch := dc.channel_get(store(), m.channel_id);
	return ch && ch.kind == .Group_DM && ((sh.result == .No_Session && sh.kind == xx e2e.Kind.Msg) || (sh.result == .Undecryptable && sh.kind == xx e2e.Kind.Init));
}

// encrypted_editable: an opened message of ours, which Edit rewrites into a new packet.
encrypted_editable :: (m: *dc.Message) -> bool {
	sh := table_find_pointer(*ee.shown, m.id);
	return sh && !sh.pending && sh.result == .Ok && is_text(sh.content);
}

// encrypted_prepare opens every packet of an encrypted DM's loaded messages, drawn or not, so the
// reactions among them reach the messages they're on.
encrypted_prepare :: (channel_id: dc.Snowflake, msgs: []dc.Message) {
	if !encrypted_dm(dc.channel_get(store(), channel_id)) return;
	for * msgs if !it.pending && begins_with(it.content, fc_text.PREFIX) encrypted_open(it.id, it.channel_id, it.content, it.author_id, it.edited_timestamp);
}

// encrypted_view is m as its packet says: its reply, its files once opened (others start downloading),
// and the encrypted reactions on it. A temp copy, or m itself when there's nothing to add.
encrypted_view :: (m: *dc.Message) -> *dc.Message {
	list := table_find_pointer(*ee.reactions, m.id);
	packet := encrypted_packet(m.channel_id, m.content);
	sh := ifx packet then table_find_pointer(*ee.shown, m.id) else null;
	opened := sh && !sh.pending && sh.result == .Ok && is_text(sh.content);
	if !opened && !list && !(packet && m.attachments) return m;
	v := New(dc.Message,, temp);
	v.* = m.*;
	if packet v.attachments = ([..]dc.Attachment).{}; // ciphertext: only what opens is shown
	if opened {
		v.referenced_id = sh.reply;
		v.sticker_ids = ([..]dc.Snowflake).{};
		v.sticker_ids.allocator = temp;
		for sh.stickers array_add(*v.sticker_ids, it);
		atts: [..]dc.Attachment;
		atts.allocator = temp;
		for f, i: sh.files {
			key := file_key(f);
			b := table_find_pointer(*blobs, key);
			if !b && !m.pending { // a pending copy has no attachments yet
				// Its ciphertext is the message's attachment in the same place, of exactly the sealed size.
				k := copy_string(key);
				b = find_or_add(*blobs, k);
				b.state = .Failed;
				if i >= m.attachments.count || (m.attachments[i].size && m.attachments[i].size != e2e.sealed_size(f.size)) continue;
				b.state = .Loading;
				o := New(Open_File);
				o.key, o.url, o.file = k, copy_string(m.attachments[i].url), f;
				o.file.name, o.file.mime, o.file.description = copy_string(f.name), copy_string(f.mime), copy_string(f.description);
				array_add(*ee.opening, o);
				blob_get(o.url);
			}
			if !b || b.state != .Ready continue;
			id: dc.Snowflake;
			memcpy(*id, f.digest.data, 8);
			name := clean_filename(f.name, "file");
			array_add(*atts, .{id = id & 0x7FFF_FFFF_FFFF_FFFF, filename = ifx f.spoiler then tprint("SPOILER_%", name) else name, content_type = f.mime, size = f.size,
				url = key, width = f.width, height = f.height, description = f.description});
		}
		v.attachments = atts;
	}
	if list {
		res: [..]dc.Reaction;
		res.allocator = temp;
		for m.reactions array_add(*res, it);
		me := store().me;
		for list.* if it.on {
			e := dc.Emoji.{name = it.emoji, available = true};
			colon := find_index_from_right(it.emoji, #char ":");
			if colon > 0 e = .{id = dc.parse_snowflake(advance(it.emoji, colon + 1)), name = slice(it.emoji, 0, colon), available = true};
			found: *dc.Reaction;
			for * res if dc.emoji_matches(it.emoji, e.id, e.name) found = it;
			if !found found = array_add(*res);
			if !found.count && !found.burst_count found.emoji = e;
			found.count += 1;
			found.me ||= it.user == me;
		}
		v.reactions = res;
	}
	return v;
}

// encrypted_reactors: who has an encrypted reaction with emoji on the message (temp), oldest first.
encrypted_reactors :: (id: dc.Snowflake, e: dc.Emoji) -> []dc.Snowflake {
	list := table_find_pointer(*ee.reactions, id);
	if !list return .[];
	out: [..]dc.Snowflake;
	out.allocator = temp;
	emoji := ifx e.id then tprint("%:%", e.name, e.id) else e.name;
	for list.* if it.on && it.emoji == emoji array_add(*out, it.user);
	return out;
}

// encrypted_react sends a reaction in an encrypted DM as a packet of its own (true: taken). toggle takes
// back ours.
encrypted_react :: (m: *dc.Message, e: dc.Emoji, toggle: bool) -> bool {
	ch := dc.channel_get(store(), m.channel_id);
	if !encrypting(ch) return false;
	if !encrypted_channel(ch.id).has_session || !identity_ready() return true;
	emoji := ifx e.id then tprint("%:%", e.name, e.id) else e.name;
	on := true;
	view := encrypted_view(m);
	if toggle for view.reactions if it.me && dc.emoji_matches(it.emoji, e.id, e.name) on = false;
	r := e2e.request(.Send, conversation(ch.id), emoji);
	group_members(r, ch);
	r.me, r.content, r.target = my_identity(), ifx on then e2e.Content.React else .Unreact, sprint("%", m.id);
	e2e_submit(r);
	reaction_note(m.id, store().me, emoji, dc.snowflake_from_ms(dc.now_ms()), on);
	return true;
}

// encrypted_edit edits our encrypted message into a new packet holding the Edit (or, with no text, the
// Delete); true when it's an encrypted one of ours, taken here.
encrypted_edit :: (channel_id: dc.Snowflake, id: dc.Snowflake, text: string, delete := false) -> bool {
	m := find_message(id);
	if !m || m.author_id != store().me || !encrypted_packet(channel_id, m.content) return false;
	sh := table_find_pointer(*ee.shown, id);
	if !sh || sh.pending || sh.result != .Ok || !is_text(sh.content) || !identity_ready() return true;
	r := e2e.request(.Send, conversation(channel_id), ifx delete then "" else text);
	group_members(r, dc.channel_get(store(), channel_id));
	r.me, r.content, r.target, r.in_place = my_identity(), ifx delete then e2e.Content.Delete else .Edit, sprint("%", id), fc_text.MAX_PACKET;
	if !delete {
		r.reply = ifx sh.reply then sprint("%", sh.reply) else "";
		r.files = files_copy(sh.files);
	}
	e2e_submit(r);
	return true;
}

// shown_text is a message's content as drawn outside the message list (previews, notifications, copies).
shown_text :: (id: dc.Snowflake, channel_id: dc.Snowflake, content: string) -> string {
	if !encrypted_packet(channel_id, content) return content;
	sh := table_find_pointer(*ee.shown, id);
	if sh && !sh.pending && sh.result == .Ok && is_text(sh.content) return ifx sh.text || !sh.files then sh.text else L("Sent a file");
	return L("Encrypted message");
}

// encrypted_dm: a DM that can be encrypted: a 1:1 DM, or a group DM (E2E 8, on Discord).
encrypted_dm :: (ch: *dc.Channel) -> bool { return ch && ((ch.kind == .DM && ch.recipient_ids.count == 1) || ch.kind == .Group_DM); }

// group_members gives a Send in a group DM its other members, each of whom gets our sender key.
group_members :: (r: *e2e.Request, ch: *dc.Channel) {
	if ch && ch.kind == .Group_DM for ch.recipient_ids array_add(*r.members, sprint("%", it));
}

// encrypting: what the composer sends in this channel goes encrypted. A hosted DM always does, and starts
// its session the first time it's shown; a hosted group starts one with each member it has none with,
// and with each who joins later.
encrypting :: (ch: *dc.Channel) -> bool {
	if !encrypted_dm(ch) return false;
	if !on_hosted() return encrypted_channel(ch.id).encrypted;
	e := encrypted_channel(ch.id);
	if !e.loaded || !identity_ready() || !e2e_db return true;
	// The member's bundle if serve has one (encrypted_bundle_receive), else a Hello for them to answer.
	if ch.kind == .DM && !e.encrypted && !e.has_session && !e.hello_asked && ch.recipient_ids.count {
		find_or_add(*ee.channels, ch.id).hello_asked = true;
		dc.e2e_bundle_call(app.client, "GET", tprint("/users/%/e2e-bundle", ch.recipient_ids[0]), channel_id = ch.id, tag = xx ch.recipient_ids[0]);
	}
	if ch.kind == .Group_DM for ch.recipient_ids if !array_find(e.peers, it) && !array_find(e.asked, it) {
		array_add(*find_or_add(*ee.channels, ch.id).asked, it);
		dc.e2e_bundle_call(app.client, "GET", tprint("/users/%/e2e-bundle", it), channel_id = ch.id, tag = xx it);
	}
	return true;
}

// encrypted_unreached: a group's members who get nothing we send yet, with no session with us (temp).
encrypted_unreached :: (ch: *dc.Channel) -> []dc.Snowflake {
	out: [..]dc.Snowflake;
	out.allocator = temp;
	if !ch || ch.kind != .Group_DM || !encrypting(ch) return out;
	e := encrypted_channel(ch.id);
	if e.loaded for ch.recipient_ids if !array_find(e.peers, it) array_add(*out, it);
	return out;
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
	if !r.channel_id return; // a published one
	bundle: []u8;
	ok := false;
	if r.ok bundle, ok = fc_text.decode(dc.fstr(dc.vmap(r.body), "bundle"), fc_text.MAX_BUNDLE);
	if !ok {
		// In a group one Hello reaches every member who has no bundle.
		dm := dc.channel_get(store(), r.channel_id);
		if !(dm && dm.kind == .Group_DM && encrypted_channel(dm.id).hello_asked) send_hello(r.channel_id);
		return;
	}
	q := e2e.request(.Accept, conversation(r.channel_id, xx r.tag, limit = fc_text.MAX_PACKET), packet = xx bundle);
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

// encrypted_send takes over the composer's send in an encrypted DM: text, a reply and the staged files
// (already uploading as ciphertext). It returns false to keep the text, e.g. while the peer hasn't
// accepted yet.
encrypted_send :: (dm: *dc.Channel, text: string, silent: bool, reply: dc.Snowflake = 0, atts: []dc.Draft_Attachment = .[]) -> bool {
	files, sealed, cts := attachments_sealed(dm.id, true);
	if !atts files, cts = .[], .[]; // a forward's note takes none of the composer's
	if !sealed && atts { toast_show(L("Remove the files added before encryption was on: they'd go unencrypted."), false); return false; }
	return encrypted_post(dm, text, silent, reply, files, atts, cts = cts);
}

// encrypted_sticker sends a sticker in an encrypted DM: its ID, format and name inside the packet.
encrypted_sticker :: (dm: *dc.Channel, id: dc.Snowflake, format_type: int, name: string) {
	encrypted_post(dm, "", false, stickers = .[tprint("% % %", id, format_type, name)]);
}

// encrypted_gif fetches a GIF (only the sender contacts its host) to send it as an encrypted file: its
// GIF rendition, else its video one.
encrypted_gif :: (dm: *dc.Channel, gif: string, video: string, width: int, height: int) {
	if !encrypted_channel(dm.id).has_session { encrypted_post(dm, "", false); return; } // says why
	url := ifx gif then gif else video;
	if !url { toast_show(L("Couldn't get that GIF."), false); return; }
	mime := ifx gif then "image/gif" else ifx ends_with(video, ".mp4") then "video/mp4" else "video/webm";
	array_add(*ee.gifs, .{dm.id, copy_string(url), width, height, mime});
	blob_get(url);
}

// encrypted_forward re-encrypts our copy of an encrypted message for dest: as an encrypted message when
// dest is encrypted, else as a plain one (the forward modal has warned). Its opened files go again, sealed
// anew or plain.
encrypted_forward :: (m: *dc.Message, dest: *dc.Channel) {
	sh := table_find_pointer(*ee.shown, m.id);
	if !sh || sh.pending || sh.result != .Ok || !is_text(sh.content) || !app.client return;
	sealing := encrypting(dest);
	files: [..]e2e.File;
	files.allocator = temp;
	atts: [..]dc.Draft_Attachment;
	atts.allocator = temp;
	cts: [..][]u8;
	cts.allocator = temp;
	for sh.files {
		b := table_find_pointer(*blobs, file_key(it));
		if !b || b.state != .Ready continue;
		f := it;
		name := clean_filename(it.name, "file");
		if sealing {
			ct := e2e.seal_file(b.data, *f);
			array_add(*atts, .{handle = dc.upload_draft(app.client, dest.id, ENCRYPTED_NAME, "application/octet-stream", ct, "forward"), filename = ENCRYPTED_NAME});
			array_add(*files, f);
			array_add(*cts, array_copy(ct,, temp));
			array_free(ct);
		} else {
			array_add(*atts, .{handle = dc.upload_draft(app.client, dest.id, name, it.mime, b.data, "forward"), filename = name, spoiler = it.spoiler});
		}
	}
	if sealing {
		stickers: [..]string;
		stickers.allocator = temp;
		for sh.stickers {
			item, ok := dc.sticker_item(store(), it);
			array_add(*stickers, tprint("% % %", it, ifx ok then item.format_type else 1, ifx ok then item.name else ""));
		}
		encrypted_post(dest, sh.text, false, files = files, atts = atts, stickers = stickers, cts = cts);
	} else {
		dc.send_message(app.client, dest.id, sh.text, .{attachments = atts, sticker_ids = sh.stickers});
	}
}

// encrypted_post sends one encrypted message: text, a reply, files with their uploads (atts, and their
// ciphertexts cts, in the same order) and stickers. false, with a toast, while it can't go.
encrypted_post :: (dm: *dc.Channel, text: string, silent: bool, reply: dc.Snowflake = 0, files: []e2e.File = .[], atts: []dc.Draft_Attachment = .[], stickers: []string = .[], cts: [][]u8 = .[]) -> bool {
	ch := encrypted_channel(dm.id);
	if !ch.has_session {
		if dm.kind == .Group_DM && on_hosted() toast_show(L("Setting up encryption: no one here can read it yet."), false);
		else toast_show(tprint(ifx on_hosted() then L("Setting up encryption: % needs to open fastcord once.") else L("% hasn't accepted encryption yet."), dm_name(dm)), false);
		return false;
	}
	most := e2e.max_text(e2e.MAX_PACKET);
	if text.count > most { toast_show(tprint(L("Encrypted messages are limited to % bytes for now."), most), false); return false; }
	if !identity_ready() return false;
	r := e2e.request(.Send, conversation(dm.id), text);
	group_members(r, dm);
	r.me, r.silent, r.reply = my_identity(), silent, ifx reply then sprint("%", reply) else "";
	r.files = files_copy(files);
	for * r.files if it.name.count > 200 { free(it.name); it.name = copy_string("file"); } // a Body holds names to 255 bytes
	for stickers array_add(*r.stickers, copy_string(it));
	for cts array_add(*r.uploads, copy_string(xx it)); // kept with the outbox entry: a resend after a crash carries them
	if atts table_set(*ee.attachments, r, array_copy(atts)); // their names are ENCRYPTED_NAME: static
	e2e_submit(r);
	return true;
}

// encrypted_body draws an `fc-` message in a 1:1 DM, or returns its plaintext for message_body to draw.
// false leaves the raw text to message_body.
encrypted_body :: (m: *dc.Message) -> handled: bool, plaintext: string {
	if !begins_with(packet_text(m.content), fc_text.PREFIX) return false, "";
	if !encrypted_dm(dc.channel_get(store(), m.channel_id)) return false, "";
	sh := ifx m.pending then table_find_pointer(*ee.shown, m.id) else encrypted_open(m.id, m.channel_id, m.content, m.author_id, m.edited_timestamp);
	muted :: (text: string) { label(text, .Normal, chat_px(MSG_FONT), T("--text-muted"), chat_px(MSG_LINE_H)); }
	if !sh || sh.pending { muted(L("Encrypted message")); return true, ""; }
	mine := m.author_id == store().me;
	name := ifx mine then L("You") else author_name(m);
	if sh.result == .Ok && is_text(sh.content) {
		failed := 0;
		for sh.files { b := table_find_pointer(*blobs, file_key(it)); if b && b.state == .Failed failed += 1; }
		if failed muted(tprint(Lp("An encrypted file couldn't be opened.", "% encrypted files couldn't be opened.", failed), failed));
		return true, sh.text;
	}
	if sh.result == .Ok && sh.content == .Delete { muted(L("Deleted message")); return true, ""; }
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
		if sh.packet {
			sh.accepted = true;
			q := e2e.request(.Accept, conversation(m.channel_id, m.author_id, fc_text.MAX_PACKET), packet = sh.packet);
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
	if !encrypted_dm(dm) || dm.kind != .DM || !identity_ready() return;
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

// encrypted_unreached_bar sits atop an encrypted group's composer and names the members who get nothing we
// send yet, having no session with us: they haven't opened fastcord since joining, or it's still starting.
encrypted_unreached_bar :: (dm: *dc.Channel) {
	who := encrypted_unreached(dm);
	if !who return;
	names: [..]string;
	names.allocator = temp;
	for who array_add(*names, dc.user_name(store(), it, 0, "unknown"));
	bar := row("unreached");
	bar.semantic_size = .[ui.pct(1), ui.px(40)];
	bar.cross_align = .Center;
	{ ui.parent(bar); defer ui.pop_parent();
		spacer(.X, 16);
		icon("warn", "warning", 16, T("--status-warning"));
		spacer(.X, 8);
		p := ui.box(tprint(L("% can't read your messages here yet.##text"), join(..names, separator = ", ",, temp)), .Draw_Text | .Clip);
		p.semantic_size = .[ui.fill(), ui.px(18)];
		p.style.font = F(.Normal);
		p.style.font_size = 14;
		p.style.line_height = 18;
		p.style.text_color = T("--text-muted");
		spacer(.X, 12);
	}
	sep := ui.box("unreachedsep", .Draw_Background);
	sep.semantic_size = .[ui.pct(1), ui.px(1)];
	sep.style.bg = T("--border-subtle");
}

// encrypted_warning sits atop the composer while the peer's identity root is new and unconfirmed.
encrypted_warning :: (dm: *dc.Channel) {
	if !encrypted_dm(dm) || dm.kind != .DM return;
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

// carrier_text is a packet as a message: `fc-` text, or the hash of the attachment that carries it, with
// the note before a Hello on Discord.
carrier_text :: (carrier: string, packet: string) -> string {
	text := ifx packet.count > fc_text.MAX_PACKET then fc_text.attached(crypto.blake3(xx packet),, temp) else fc_text.encode(xx packet,, temp);
	hello := packet.count >= 2 && packet[1] == xx e2e.Kind.Hello;
	return ifx hello && carrier == DISCORD then tprint("%1%2", HELLO_NOTE, text) else text;
}

carrier_client :: (name: string) -> *dc.Client {
	for connections() if carrier_name(it) == name return it;
	return null;
}

// conversation names a 1:1 DM on the selected connection to the e2e core; peer defaults to the DM's recipient.
// limit: a packet larger than a message goes as the message's attachment (an edit can't add one, so a
// longer edit goes as a hidden message of its own), and an Accept's Init fits one message when its padding
// stops there.
conversation :: (channel_id: dc.Snowflake, peer: dc.Snowflake = 0, limit := e2e.MAX_PACKET) -> e2e.Conversation {
	s := store();
	ch := dc.channel_get(s, channel_id);
	if !peer && ch && ch.recipient_ids.count peer = ch.recipient_ids[0];
	return .{carrier_name(app.client), tprint("%", channel_id), tprint("%", s.me), tprint("%", peer), limit};
}

identity_ready ::() -> bool { return atomic_load(*idk.done) != 0 && idk.list.count > 0; }

my_identity :: () -> e2e.Identity { return e2e.identity_of(idk.list[0]); }

e2e_submit :: (r: *e2e.Request) {
	array_add(*ee.inflight, r);
	e2e.submit(e2e_db, r);
}

// send_packet hands a committed packet to its carrier, shows its pending copy as what it holds, and drops
// it from the outbox. An Edit or Delete edits its message instead, which shows the change at once.
send_packet :: (r: *e2e.Request, result: e2e.Result, text: string, content := e2e.Content.Text) {
	_, atts := table_remove(*ee.attachments, r);
	defer free(atts.data);
	c := carrier_client(r.conv.carrier);
	if !c return; // The outbox sends it on the next start.
	channel := dc.parse_snowflake(r.conv.id);
	// In a group, our new sender key goes first, one packet per member (E2E 8).
	for i: 0..r.packets.count - 2 {
		gift := find_or_add(*ee.shown, post_packet(c, channel, r.conv.carrier, r.packets[i], true));
		gift.* = .{result = .Ok, content = .Sender_Key, sent = true}; // hidden while it's on its way
		e2e_submit(e2e.request(.Sent, packet = r.packets[i]));
	}
	if content == .Edit || content == .Delete {
		target := dc.parse_snowflake(r.target);
		if r.detached {
			own := find_or_add(*ee.shown, post_packet(c, channel, r.conv.carrier, r.packet, true));
			own.* = .{result = .Ok, content = .Edit, detached = true, sent = true}; // hidden while it's on its way
		} else {
			dc.edit_message(c, channel, target, carrier_text(r.conv.carrier, r.packet));
		}
		sh := table_find_pointer(*ee.shown, target);
		if sh { free(sh.text); sh.text, sh.content = copy_string(text), content; } // until the edit comes back
		e2e_submit(e2e.request(.Sent, packet = r.packet));
		return;
	}
	// The carrier's own flag too, so its push stays quiet; it says nothing about the content.
	nonce := post_packet(c, channel, r.conv.carrier, r.packet, r.silent, atts);
	sh := find_or_add(*ee.shown, nonce);
	shown_free(sh);
	sh.* = .{result = result, content = content, text = copy_string(text), silent = r.silent, reply = dc.parse_snowflake(r.reply), files = files_copy(r.files), sent = true,
		stickers = stickers_of(r.stickers)};
	e2e_submit(e2e.request(.Sent, packet = r.packet));
}

// post_packet sends a packet as a new message after atts; one larger than a message is uploaded as its
// last attachment. The carrier's own @silent flag too, so its push stays quiet; it says nothing of the content.
post_packet :: (c: *dc.Client, channel: dc.Snowflake, carrier: string, packet: string, silent: bool, atts: []dc.Draft_Attachment = .[]) -> dc.Snowflake {
	all := atts;
	if packet.count > fc_text.MAX_PACKET {
		all = NewArray(atts.count + 1, dc.Draft_Attachment,, temp);
		memcpy(all.data, atts.data, atts.count * size_of(dc.Draft_Attachment));
		all[atts.count] = .{handle = dc.upload_draft(c, channel, fc_text.ATTACHMENT_NAME, "application/octet-stream", xx packet), filename = fc_text.ATTACHMENT_NAME};
	}
	return dc.send_message(c, channel, carrier_text(carrier, packet), .{flags = ifx silent then SUPPRESS_NOTIFICATIONS else 0, attachments = all});
}

is_text :: (c: e2e.Content) -> bool { return c == .Text || c == .Post || c == .Edit; }

// stickers_of reads the stickers a packet names as "id format name", noting each for the renderer.
stickers_of :: (named: []string) -> [..]dc.Snowflake {
	out: [..]dc.Snowflake;
	for named {
		f := split(it, " ",, temp);
		if f.count < 2 continue;
		id, format := dc.parse_snowflake(f[0]), string_to_int(f[1]);
		if !id || format < 1 || format > 4 continue;
		dc.note_sticker(id, ifx f.count > 2 then slice(it, f[0].count + f[1].count + 2, it.count - f[0].count - f[1].count - 2) else "", format);
		array_add(*out, id);
	}
	return out;
}

shown_free :: (sh: *Shown) {
	array_free(sh.stickers);
	free(sh.text);
	free(sh.packet);
	free(sh.edited);
	files_free(*sh.files);
}

files_copy :: (files: []e2e.File) -> [..]e2e.File {
	out: [..]e2e.File;
	for files {
		f := array_add(*out);
		f.* = it;
		f.name, f.mime, f.description = copy_string(it.name), copy_string(it.mime), copy_string(it.description);
	}
	return out;
}

files_free :: (files: *[..]e2e.File) {
	for * files.* { crypto.zero(*it.key); free(it.name); free(it.mime); free(it.description); }
	array_free(files.*);
	files.* = ([..]e2e.File).{};
}

// file_key names an opened file by its ciphertext's digest (temp).
file_key :: (f: e2e.File) -> string {
	HEX :: "0123456789abcdef";
	out := alloc_string(E2E_URL.count + 64,, temp);
	memcpy(out.data, E2E_URL.data, E2E_URL.count);
	for f.digest { out[E2E_URL.count + it_index * 2] = HEX[it >> 4]; out[E2E_URL.count + it_index * 2 + 1] = HEX[it & 15]; }
	return out;
}

// reaction_note keeps the newest word of user on emoji for the message target.
reaction_note :: (target: dc.Snowflake, user: dc.Snowflake, emoji: string, at: dc.Snowflake, on: bool) {
	if !target || !user || !emoji return;
	list := find_or_add(*ee.reactions, target);
	for * list.* if it.user == user && it.emoji == emoji {
		if at >= it.at it.at, it.on = at, on;
		return;
	}
	array_add(list, .{user, copy_string(emoji), at, on});
	app.ui.animating = true;
}
