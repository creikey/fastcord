// DAVE for hosted voice: serve is each room's MLS delivery service, as Discord's voice gateway is, so calls are
// end-to-end encrypted. It sends the room's external sender (op 25) and takes members' key packages (op 26);
// joins and leaves become external Add and Remove proposals (op 27) to the members; the first commit back
// (op 28) is announced to them (op 29) and its welcome goes to the joiners (op 30); once they all acked
// (op 23) the transition executes (op 22). One transition runs at a time. Serve keeps no group secrets: it
// tracks only who holds which leaf, which follows from its own proposals.
//   The first member founds the group: their own one-member group (their client's pending group) at epoch 0.

DAVE_VERSION :: 1;
OP_EXECUTE_TRANSITION :: 22;
OP_READY_FOR_TRANSITION :: 23;
OP_MLS_EXTERNAL_SENDER :: 25;
OP_MLS_KEY_PACKAGE :: 26;
OP_MLS_PROPOSALS :: 27;
OP_MLS_COMMIT_WELCOME :: 28;
OP_MLS_ANNOUNCE_COMMIT :: 29;
OP_MLS_WELCOME :: 30;
OP_INVALID_COMMIT_WELCOME :: 31;
MAX_KEY_PACKAGE :: 4096;
TRANSITION_TIMEOUT_MS :: 5000; // A commit or the readies that don't come by then.

Dave_Group :: struct {
	room: s64;
	channel: s64;          // The group ID clients use: the voice channel's, a stream's too.
	ext_priv: [mls.NSK]u8; // The room's external sender, which signs the proposals.
	ext_raw: []u8;         // Its ExternalSender, as op 25 carries it; heap.
	epoch: u64;
	leaves: [..]s64;       // The member at each leaf, 0 for a blank one; empty until someone founds it.
	transition: int;       // In flight, 0 when none: committing (proposals out) or waiting for readies.
	committing: bool;
	removes: [..]u32;      // The leaves the proposals in flight remove.
	deadline_ms: s64;
	last: int;             // The last transition ID, so they keep rising (1 to 65535).
}

// dave_joined: vs has its transport key, so it learns the room's external sender; voice_mu is not held.
dave_joined :: (s: *Server, vs: *Voice_Session) {
	locks.guard(*s.voice_mu);
	g := dave_group(s, vs.room);
	if !g {
		g = New(Dave_Group);
		g.room = vs.room;
		g.channel = vs.room;
		for s.voice_states if it.stream == vs.room g.channel = it.channel;
		pub: [mls.NPK]u8;
		g.ext_priv, pub = mls.generate_signature_key();
		w := mls.writer_make(context.allocator);
		mls.w_external_sender(*w, .{signature_key = pub, credential = .{mls.CRED_BASIC, .[0]}});
		g.ext_raw = w.buf;
		array_add(*s.dave_groups, g);
	}
	dave_send(vs, OP_MLS_EXTERNAL_SENDER, g.ext_raw);
}

dave_group :: (s: *Server, room: s64) -> *Dave_Group {
	for s.dave_groups if it.room == room return it;
	return null;
}

// dave_send queues a binary op: [sequence u16][op][payload], with sequence 0, which no JSON frame starts with.
dave_send :: (vs: *Voice_Session, op: int, payload: []u8, transition := -1) {
	head := ifx transition >= 0 then 5 else 3;
	b := NewArray(head + payload.count, u8,, temp);
	b[2] = cast(u8) op;
	if transition >= 0 put_u16(b, cast(u16) transition, 3);
	memcpy(b.data + head, payload.data, payload.count);
	locks.guard(*vs.conn.mu);
	queue(vs.conn, b);
}

// dave_binary handles op 26 and op 28 from vs; false for a malformed one, which closes the connection.
dave_binary :: (s: *Server, vs: *Voice_Session, op: u8, payload: []u8) -> bool {
	locks.guard(*s.voice_mu);
	g := dave_group(s, vs.room);
	if !g return true;
	if op == OP_MLS_KEY_PACKAGE {
		if payload.count > MAX_KEY_PACKAGE return false;
		r := mls.reader_make(payload);
		kp := mls.r_key_package(*r);
		// The credential must name this member, or they could join the group as someone else.
		id := be_bytes(cast(u64) vs.user);
		if !mls.r_done(*r) || mls.validate_key_package(*kp) != .None || kp.leaf.credential.type != mls.CRED_BASIC || !mls.bytes_equal(kp.leaf.credential.data, id) return false;
		array_free(vs.key_package);
		vs.key_package = array_copy(payload);
		dave_advance(s, g);
	} else if op == OP_MLS_COMMIT_WELCOME {
		if !g.committing || !vs.in_group return true; // Late, or from someone who can't commit: ignored.
		r := mls.reader_make(payload);
		commit := mls.r_mls_message_raw(*r);
		if !commit.data return false;
		welcome := array_view(payload, commit.count, payload.count - commit.count);
		adding := false;
		for s.voice_sessions if it.room == g.room && it.adding adding = true;
		if adding && !welcome.count return true;
		for s.voice_sessions if it.room == g.room && it.in_group dave_send(it, OP_MLS_ANNOUNCE_COMMIT, commit, g.transition);
		// The tree as the commit leaves it: removes first, then each add in the leftmost blank leaf, in the
		// order the proposals went out (MLS applies them so), then trailing blanks dropped.
		for g.removes g.leaves[it] = 0;
		while g.leaves.count && !peek(g.leaves) pop(*g.leaves);
		for s.voice_sessions if it.room == g.room && it.adding {
			dave_send(it, OP_MLS_WELCOME, welcome, g.transition);
			it.adding, it.in_group = false, true;
			found, at := array_find(g.leaves, 0);
			if found g.leaves[at] = it.user;
			else array_add(*g.leaves, it.user);
			array_free(it.key_package);
			it.key_package = .[];
		}
		for s.voice_sessions if it.room == g.room it.ready = false;
		g.epoch += 1;
		g.committing = false;
		g.removes.count = 0;
		g.deadline_ms = now_ms(s) + TRANSITION_TIMEOUT_MS;
	}
	return true;
}

// dave_ack: op 23 (ready) or op 31 (the commit or welcome failed: the client starts over with a new key
// package, so its leaf goes and it joins again).
dave_ack :: (s: *Server, vs: *Voice_Session, transition: int, ready: bool) {
	locks.guard(*s.voice_mu);
	g := dave_group(s, vs.room);
	if !g return;
	if ready && transition == g.transition && !g.committing vs.ready = true;
	if !ready vs.in_group = false;
	dave_advance(s, g);
}

// dave_left: vs ended; voice_mu is held. Its leaf goes in the next transition, and an empty room's group goes.
dave_left :: (s: *Server, vs: *Voice_Session) {
	g := dave_group(s, vs.room);
	if !g return;
	for s.voice_sessions if it.room == g.room { dave_advance(s, g); return; }
	array_free(g.ext_raw);
	array_free(g.leaves);
	array_free(g.removes);
	array_unordered_remove_by_value(*s.dave_groups, g);
	free(g);
}

// dave_tick runs out transitions whose time is up; it takes voice_mu.
dave_tick :: (s: *Server) {
	locks.guard(*s.voice_mu);
	now := now_ms(s);
	for s.dave_groups if it.transition && now >= it.deadline_ms {
		// Readies that didn't come: the transition executes without them, as a late member only switches late.
		// No commit: the members' groups can't be trusted to agree, so every connection starts over.
		if !it.committing {
			dave_execute(s, it);
			dave_advance(s, it);
			continue;
		}
		kick_locked(s, 0, it.room);
		for v: s.voice_sessions if v.room == it.room v.in_group, v.adding = false, false;
		it.leaves.count, it.removes.count, it.transition, it.committing = 0, 0, 0, false;
	}
}

dave_execute :: (s: *Server, g: *Dave_Group) {
	for s.voice_sessions if it.room == g.room && it.in_group voice_send(it.conn, tprint("{\"op\":%,\"d\":{\"transition_id\":%}}", OP_EXECUTE_TRANSITION, g.transition));
	g.transition = 0;
}

// dave_advance finishes the transition in flight once its readies are in, then starts the next if someone
// joined or left. voice_mu is held.
dave_advance :: (s: *Server, g: *Dave_Group) {
	if g.transition {
		if g.committing return;
		for s.voice_sessions if it.room == g.room && it.in_group && !it.ready return;
		dave_execute(s, g);
	}
	present :: (user: s64) -> bool #expand {
		for `s.voice_sessions if it.room == `g.room && it.in_group && it.user == user return true;
		return false;
	}
	members := 0;
	for s.voice_sessions if it.room == g.room && it.in_group members += 1;
	if !members {
		// No group yet, or everyone in it left: the first member whose key package is in founds a new one, their
		// own one-member group at epoch 0.
		g.leaves.count, g.epoch = 0, 0;
		for s.voice_sessions if it.room == g.room && it.key_package.count {
			it.in_group = true;
			array_add(*g.leaves, it.user);
			array_free(it.key_package);
			it.key_package = .[];
			break;
		}
		if !g.leaves.count return;
	}
	gid := be_bytes(cast(u64) g.channel);
	all: [..]u8;
	all.allocator = temp;
	for g.leaves if it && !present(it) {
		msg, ok := mls.external_proposal(gid, g.epoch, 0, .{type = .Remove, remove_ = cast(u32) it_index}, g.ext_priv,, temp);
		if !ok return;
		array_add(*all, ..msg);
		array_add(*g.removes, cast(u32) it_index);
	}
	for s.voice_sessions if it.room == g.room && it.key_package.count && !it.in_group && !present(it.user) {
		r := mls.reader_make(it.key_package);
		msg, ok := mls.external_proposal(gid, g.epoch, 0, .{type = .Add, add = mls.r_key_package(*r)}, g.ext_priv,, temp);
		if !ok return;
		array_add(*all, ..msg);
		it.adding = true;
	}
	if !all.count return;
	w := mls.writer_make();
	mls.w_u8(*w, 0); // Append.
	mls.w_vec(*w, all);
	for s.voice_sessions if it.room == g.room && it.in_group dave_send(it, OP_MLS_PROPOSALS, w.buf);
	g.last = g.last % 65535 + 1;
	g.transition, g.committing = g.last, true;
	g.deadline_ms = now_ms(s) + TRANSITION_TIMEOUT_MS;
}

be_bytes :: (x: u64) -> [8]u8 {
	b: [8]u8;
	for * b it.* = cast,no_check(u8) (x >> (56 - 8 * it_index));
	return b;
}

