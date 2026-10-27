// Group: one epoch of MLS group state. Every state transition (commit,
// welcome) produces a NEW Group with its own arena, leaving the old one
// intact (DAVE keeps the previous epoch around until a transition executes).

Node_Priv :: struct {
	priv: [NSK]u8;
	pub: [NPK]u8;
}

Epoch_Secrets :: struct {
	joiner: Secret;
	welcome: Secret;
	epoch: Secret;
	sender_data: Secret;
	encryption: Secret;
	exporter: Secret;
	external: Secret;
	confirmation_key: Secret;
	membership_key: Secret;
	resumption_psk: Secret;
	epoch_authenticator: Secret;
	init: Secret;
}

Cached_Proposal :: struct {
	ref: Secret;
	proposal: Proposal;
	sender: Sender;
}

Psk_Entry :: struct {
	id: []u8;
	secret: []u8;
}

Resumption_Entry :: struct {
	epoch: u64;
	secret: Secret;
}

// Identity is the long-lived signing identity of the local member.
Identity :: struct {
	sig_priv: [NSK]u8;
	sig_pub: [NPK]u8;
	credential: Credential;
}

Group :: struct {
	arena: virtual.Arena;
	alloc: Allocator;
	ctx: Group_Context;
	tree: Tree;
	my_leaf: u32;
	sig_priv: [NSK]u8;
	privs: Map(u32, Node_Priv);
	interim: Secret;
	ks: Epoch_Secrets;
	proposals: [..]Cached_Proposal;
	ext_psks: [..]Psk_Entry;
	resumption: [..]Resumption_Entry; // previous epochs (most recent last)
}

group_alloc :: () -> *Group {
	g := new(Group);
	if virtual.arena_init_growing(*g.arena) != null {
		free(g);
		return null;
	}
	g.alloc = virtual.arena_allocator(*g.arena);
	g.privs = Map(u32, Node_Priv).{};
	g.proposals = make_dynamic(Cached_Proposal, 0, 4, g.alloc);
	g.ext_psks = make_dynamic(Psk_Entry, 0, 1, g.alloc);
	g.resumption = make_dynamic(Resumption_Entry, 0, 4, g.alloc);
	return g;
}

group_destroy :: (g: *Group) {
	if g == null { return; }
	crypto.zero_explicit(*g.ks, size_of(g.ks));
	crypto.zero_explicit(*g.sig_priv, size_of(g.sig_priv));
	virtual.arena_destroy(*g.arena);
	free(g);
}

group_add_external_psk :: (g: *Group, id: []u8, secret: []u8) {
	append(*g.ext_psks, Psk_Entry.{clone_bytes(id, g.alloc), clone_bytes(secret, g.alloc)});
}

epoch :: (g: *Group) -> u64 {return g.ctx.epoch;}
group_id :: (g: *Group) -> []u8 {return g.ctx.group_id;}
epoch_authenticator :: (g: *Group) -> Secret {return g.ks.epoch_authenticator;}

// exporter: MLS-Exporter(label, context, length) (RFC 9420 8.5).
exporter :: (g: *Group, label: string, ctx: []u8, dst: []u8) {
	s := derive_secret(view(g.ks.exporter), label);
	h := hash_bytes(ctx);
	expand_with_label(view(s), "exported", view(h), dst);
}

member_leaf :: (g: *Group, leaf: u32) -> *Leaf_Node, bool {
	n := leaf_at(*g.tree, leaf);
	if n == null || n.kind != .Leaf { return null, false; }
	return *n.leaf, true;
}

// ---------------------------------------------------------------------------
// Key schedule

key_schedule_from_joiner :: (ks: *Epoch_Secrets, psk_secret: []u8, ctx_bytes: []u8) {
	zero: Secret;
	psk := ifx len(psk_secret) > 0 then psk_secret else view(zero);
	m := kdf_extract(view(ks.joiner), psk);
	ks.welcome = derive_secret(view(m), "welcome");
	expand_with_label(view(m), "epoch", ctx_bytes, view(ks.epoch));
	key_schedule_from_epoch(ks);
}

key_schedule_from_epoch :: (ks: *Epoch_Secrets) {
	e := view(ks.epoch);
	ks.sender_data = derive_secret(e, "sender data");
	ks.encryption = derive_secret(e, "encryption");
	ks.exporter = derive_secret(e, "exporter");
	ks.external = derive_secret(e, "external");
	ks.confirmation_key = derive_secret(e, "confirm");
	ks.membership_key = derive_secret(e, "membership");
	ks.resumption_psk = derive_secret(e, "resumption");
	ks.epoch_authenticator = derive_secret(e, "authentication");
	ks.init = derive_secret(e, "init");
}

key_schedule :: (init_prev: []u8, commit_secret: []u8, psk_secret: []u8, ctx_bytes: []u8) -> Epoch_Secrets {
	ks: Epoch_Secrets;
	x := kdf_extract(init_prev, commit_secret);
	expand_with_label(view(x), "joiner", ctx_bytes, view(ks.joiner));
	key_schedule_from_joiner(*ks, psk_secret, ctx_bytes);
	return ks;
}

welcome_key_nonce :: (welcome_secret: []u8) -> [NK]u8, [NN]u8 {
	key: [NK]u8;
	nonce: [NN]u8;
	expand_with_label(welcome_secret, "key", null, view(key));
	expand_with_label(welcome_secret, "nonce", null, view(nonce));
	return key, nonce;
}

// psk_secret (RFC 9420 8.4). lookup returns the PSK value for an id.
compute_psk_secret :: (g: *Group, psks: []Psk_Id) -> Secret, Error {
	out: Secret;
	err: Error;
	if len(psks) == 0 { return out, err; }
	zero: Secret;
	acc := zero;
	for p, i: psks {
		value: []u8;
		if p.type == {
		case 1;
			for e: g.ext_psks { if bytes_equal(e.id, p.id) { value = e.secret; } }
		case 2;
			if p.usage != 1 { return out, .Unsupported; } // only "application" resumption
			if !bytes_equal(p.group_id, g.ctx.group_id) { return out, .Unsupported; }
			if p.epoch == g.ctx.epoch {
				value = view(g.ks.resumption_psk);
			} else {
				for * e: g.resumption { if e.epoch == p.epoch { value = view(e.secret); } }
			}
		}
		if value == null { return out, .State; }
		extracted := kdf_extract(null, value);
		w := writer_make();
		w_psk_id(*w, p);
		w_u16(*w, cast(u16)(i));
		w_u16(*w, cast(u16)(len(psks)));
		input: Secret;
		expand_with_label(view(extracted), "derived psk", view(w.buf), view(input));
		acc = kdf_extract(view(input), view(acc));
	}
	return acc, .None;
}

// ---------------------------------------------------------------------------
// Transcript hashes

confirmed_hash :: (interim: []u8, wire_format: Wire_Format, content_raw: []u8, signature: []u8) -> Secret {
	w := writer_make();
	w_raw(*w, interim);
	w_u16(*w, cast(u16)(wire_format));
	w_raw(*w, content_raw);
	w_vec(*w, signature);
	return hash_bytes(view(w.buf));
}

interim_hash :: (confirmed: []u8, confirmation_tag: []u8) -> Secret {
	w := writer_make();
	w_raw(*w, confirmed);
	w_vec(*w, confirmation_tag);
	return hash_bytes(view(w.buf));
}

// ---------------------------------------------------------------------------
// Framing helpers

framed_content_tbs :: (content_raw: []u8, sender: Sender, ctx_bytes: []u8) -> []u8 {
	w := writer_make();
	w_u16(*w, PROTOCOL_VERSION);
	w_u16(*w, cast(u16)(Wire_Format.Public_Message));
	w_raw(*w, content_raw);
	if sender.type == .Member || sender.type == .New_Member_Commit { w_raw(*w, ctx_bytes); }
	return view(w.buf);
}

auth_data_bytes :: (signature: []u8, confirmation_tag: []u8, is_commit: bool) -> []u8 {
	w := writer_make();
	w_vec(*w, signature);
	if is_commit { w_vec(*w, confirmation_tag); }
	return view(w.buf);
}

// authenticated_content: wire_format || FramedContent || FramedContentAuthData
authenticated_content :: (content_raw: []u8, signature: []u8, confirmation_tag: []u8, is_commit: bool) -> []u8 {
	w := writer_make();
	w_u16(*w, cast(u16)(Wire_Format.Public_Message));
	w_raw(*w, content_raw);
	w_raw(*w, auth_data_bytes(signature, confirmation_tag, is_commit));
	return view(w.buf);
}

proposal_ref :: (content_raw: []u8, signature: []u8) -> Secret {
	return ref_hash("MLS 1.0 Proposal Reference", authenticated_content(content_raw, signature, null, false));
}

key_package_ref :: (kp_raw: []u8) -> Secret {
	return ref_hash("MLS 1.0 KeyPackage Reference", kp_raw);
}

external_senders :: (g: *Group, a := temp) -> []External_Sender {
	e, ok := find_extension(g.ctx.extensions, EXT_EXTERNAL_SENDERS);
	if !ok { return .{}; }
	r := reader_make(e.data);
	sub := r_sub(*r);
	out := make_dynamic(External_Sender, 0, 1);
	while r_ok(*sub) && r_left(*sub) > 0 { append(*out, r_external_sender(*sub)); }
	return view(out);
}

external_senders_extension :: (senders: []External_Sender, a := temp) -> Extension {
	w := writer_make(a);
	p := w_begin(*w);
	for s: senders { w_external_sender(*w, s); }
	w_end(*w, p);
	return Extension.{EXT_EXTERNAL_SENDERS, view(w.buf)};
}

// verify_public_message: epoch / group checks, signature and membership tag.
verify_public_message :: (g: *Group, pm: *Public_Message) -> Error {
	fc := *pm.content;
	if !bytes_equal(fc.group_id, g.ctx.group_id) { return .State; }
	if fc.epoch != g.ctx.epoch { return .State; }
	ctx_bytes := group_context_bytes(g.ctx);
	sig_key: []u8;
	if fc.sender.type == {
	case .Member;
		ln, ok := member_leaf(g, fc.sender.index);
		if !ok { return .State; }
		sig_key = ln.signature_key;
	case .External;
		es := external_senders(g);
		if cast(int)(fc.sender.index) >= len(es) { return .State; }
		sig_key = es[fc.sender.index].signature_key;
	case;
		return .Unsupported;
	}
	tbs := framed_content_tbs(fc.raw, fc.sender, ctx_bytes);
	if !verify_with_label(sig_key, "FramedContentTBS", tbs, pm.signature) { return .Verify; }
	if fc.sender.type == .Member {
		w := writer_make();
		w_raw(*w, tbs);
		w_raw(*w, auth_data_bytes(pm.signature, pm.confirmation_tag, fc.content_type == .Commit));
		tag := mac(view(g.ks.membership_key), view(w.buf));
		if !bytes_equal(view(tag), pm.membership_tag) { return .Verify; }
	}
	return .None;
}

validate_key_package :: (kp: *Key_Package) -> Error {
	if kp.version != PROTOCOL_VERSION || kp.cipher_suite != CIPHER_SUITE { return .Unsupported; }
	if kp.leaf.source != .Key_Package { return .Verify; }
	if bytes_equal(kp.init_key, kp.leaf.encryption_key) { return .Verify; }
	if !verify_with_label(kp.leaf.signature_key, "KeyPackageTBS", key_package_tbs(kp.*), kp.signature) { return .Verify; }
	if !verify_leaf_signature(kp.leaf, null, 0) { return .Verify; }
	return .None;
}

// group_cache_proposal verifies and caches a proposal (PublicMessage bytes).
// Returns the cached proposal ref.
group_cache_proposal :: (g: *Group, msg_bytes: []u8) -> Secret, *Cached_Proposal, Error {
	ref: Secret;
	prop: *Cached_Proposal;
	err: Error;
	b := clone_bytes(msg_bytes, g.alloc);
	m, __e3 := parse_mls_message(b, g.alloc); if failed(__e3) return ref, prop, __e3;
	if m.wire_format != .Public_Message { return ref, null, .Unsupported; }
	pm := *m.public;
	if pm.content.content_type != .Proposal { return ref, null, .State; }
	__e4 := verify_public_message(g, pm); if failed(__e4) return ref, prop, __e4;
	ref = proposal_ref(pm.content.raw, pm.signature);
	for * c: g.proposals { if c.ref == ref { return ref, *c, .None; } }
	if pm.content.proposal.type == .Add {
		__e5 := validate_key_package(*pm.content.proposal.add); if failed(__e5) return ref, prop, __e5;
	}
	append(*g.proposals, Cached_Proposal.{ref = ref, proposal = pm.content.proposal, sender = pm.content.sender});
	return ref, *g.proposals[len(g.proposals) - 1], .None;
}

group_revoke_proposal :: (g: *Group, ref: []u8) -> bool {
	for * c, i: g.proposals {
		if bytes_equal(view(c.ref), ref) {
			ordered_remove(*g.proposals, i);
			return true;
		}
	}
	return false;
}
#scope_module

// ---------------------------------------------------------------------------
// Rebase: deep copy the tree / context into another group's arena by
// serializing and re-parsing.

copy_tree :: (t: *Tree, a: Allocator) -> Tree, Error {
	out: Tree;
	err: Error;
	if len(t.nodes) == 0 { return out, .State; }
	b := clone_bytes(ratchet_tree_bytes(t), a);
	out, err = parse_ratchet_tree(b, a);
	if err != .None { return out, err; }
	// preserve full width (parse trims to the minimal full tree)
	while len(out.nodes) < len(t.nodes) { append(*out.nodes, Node.{}); }
	return out, err;
}

copy_context :: (gc: Group_Context, a: Allocator) -> Group_Context, Error {
	out: Group_Context;
	err: Error;
	b := clone_bytes(group_context_bytes(gc), a);
	r := reader_make(b);
	out = r_group_context(*r, a);
	if !r_done(*r) { return out, .Decode; }
	return out, .None;
}

inherit :: (old: *Group, ng: *Group) {
	ng.my_leaf = old.my_leaf;
	ng.sig_priv = old.sig_priv;
	for e: old.ext_psks { append(*ng.ext_psks, Psk_Entry.{clone_bytes(e.id, ng.alloc), clone_bytes(e.secret, ng.alloc)}); }
	for e: old.resumption { append(*ng.resumption, e); }
	append(*ng.resumption, Resumption_Entry.{old.ctx.epoch, old.ks.resumption_psk});
	if len(ng.resumption) > 16 { ordered_remove(*ng.resumption, 0); }
}

// drop private keys whose node changed
prune_privs :: (g: *Group) {
	stale := make_dynamic(u32, 0, 4, temp);
	for idx, np: g.privs {
		if cast(int)(idx) >= len(g.tree.nodes) {
			append(*stale, idx);
			continue;
		}
		k := node_encryption_key(*g.tree.nodes[idx]);
		pub := np.pub;
		if !bytes_equal(k, view(pub)) { append(*stale, idx); }
	}
	for idx: stale { delete_key(*g.privs, idx); }
}
#scope_export

// ---------------------------------------------------------------------------
// Creation & key packages

Key_Package_Secrets :: struct {
	init_priv: [NSK]u8;
	leaf_priv: [NSK]u8;
}

default_capabilities :: () -> Capabilities {
	return Capabilities.{versions = view(static_versions6), cipher_suites = view(static_suites7), credentials = view(static_creds8)};
}

// key_package_create builds a signed KeyPackage the way libdave does:
// basic credential, lifetime [0, 2^64-1], no extensions. Returns the
// KeyPackage (serialized as an MLSMessage) and its private keys.
key_package_create :: (id: *Identity, allocator := context.allocator) -> []u8, Key_Package, Key_Package_Secrets {
	msg: []u8;
	kp: Key_Package;
	secrets: Key_Package_Secrets;
	init := generate_key_pair();
	leaf := generate_key_pair();
	secrets.init_priv = init.priv;
	secrets.leaf_priv = leaf.priv;
	kp.version = PROTOCOL_VERSION;
	kp.cipher_suite = CIPHER_SUITE;
	kp.init_key = clone_bytes(view(init.pub), allocator);
	kp.leaf = Leaf_Node.{
		encryption_key = clone_bytes(view(leaf.pub), allocator),
		signature_key = clone_bytes(view(id.sig_pub), allocator),
		credential = Credential.{id.credential.type, clone_bytes(id.credential.data, allocator)},
		capabilities = default_capabilities(),
		source = .Key_Package,
		not_before = 0,
		not_after = U64_MAX
	};
	sig, ok := sign_with_label(view(id.sig_priv), "LeafNodeTBS", leaf_node_tbs(kp.leaf, null, 0), allocator);
	assert(ok);
	kp.leaf.signature = sig;
	sig2, ok2 := sign_with_label(view(id.sig_priv), "KeyPackageTBS", key_package_tbs(kp), allocator);
	assert(ok2);
	kp.signature = sig2;
	w := writer_make(allocator);
	w_u16(*w, PROTOCOL_VERSION);
	w_u16(*w, cast(u16)(Wire_Format.Key_Package));
	w_key_package(*w, kp);
	msg = view(w.buf);
	kp.raw = sub_from(msg, 4);
	return msg, kp, secrets;
}

// group_create: a one-member group at epoch 0 using the leaf from our key package.
group_create :: (gid: []u8, id: *Identity, kp: *Key_Package, secrets: *Key_Package_Secrets, extensions: []Extension) -> *Group, Error {
	g: *Group;
	err: Error;
	g = group_alloc();
	a := g.alloc;
	g.sig_priv = id.sig_priv;
	g.tree.nodes = make_dynamic(Node, 0, 1);
	b := clone_bytes(kp.raw, a);
	r := reader_make(b);
	kp2 := r_key_package(*r, a);
	if !r_done(*r) {
		group_destroy(g);
		return null, .Decode;
	}
	append(*g.tree.nodes, Node.{kind = .Leaf, leaf = kp2.leaf});
	g.my_leaf = 0;
	lp, _ := public_from_private(view(secrets.leaf_priv));
	at(*g.privs, 0).* = Node_Priv.{secrets.leaf_priv, lp};
	th := root_tree_hash(*g.tree);
	gc := Group_Context.{
		version = PROTOCOL_VERSION,
		cipher_suite = CIPHER_SUITE,
		group_id = gid,
		epoch = 0,
		tree_hash = view(th),
		extensions = extensions
	};
	g.ctx, err = copy_context(gc, a);
	if err != .None {
		group_destroy(g);
		return null, err;
	}
	crypto.rand_bytes(view(g.ks.epoch));
	key_schedule_from_epoch(*g.ks);
	tag := mac(view(g.ks.confirmation_key), null);
	g.interim = interim_hash(null, view(tag));
	return g, .None;
}
#scope_module

// ---------------------------------------------------------------------------
// Proposal application (shared by commit creation and processing)

Applied :: struct {
	joiners: [..]u32; // new leaf indices
	joiner_kps: [..]*Key_Package;
	psks: [..]Psk_Id;
	new_exts: []Extension;
	has_new_exts: bool;
	path_required: bool;
	removed_self: bool;
}

apply_proposals :: (g: *Group, ng: *Group, props: []*Proposal, senders: []Sender, committer: u32) -> Applied, Error {
	ap: Applied;
	err: Error;
	ap.joiners = make_dynamic(u32, 0, 2, temp);
	ap.joiner_kps = make_dynamic(*Key_Package, 0, 2, temp);
	ap.psks = make_dynamic(Psk_Id, 0, 1, temp);
	if len(props) == 0 { ap.path_required = true; }
	t := *ng.tree;
	// 1. GroupContextExtensions
	for p: props {
		if p.type == .Group_Context_Extensions {
			if ap.has_new_exts { return ap, .Verify; }
			ap.new_exts = p.extensions;
			ap.has_new_exts = true;
			ap.path_required = true;
		}
	}
	// 2. Updates
	for p, i: props {
		if p.type != .Update { continue; }
		s := senders[i];
		if s.type != .Member || s.index == committer { return ap, .Verify; }
		if p.update.source != .Update { return ap, .Verify; }
		if !verify_leaf_signature(p.update, g.ctx.group_id, s.index) { return ap, .Verify; }
		n := leaf_at(t, s.index);
		if n == null || n.kind != .Leaf { return ap, .Verify; }
		n.leaf = p.update;
		tree_blank_path(t, s.index);
		ap.path_required = true;
	}
	// 3. Removes
	for p: props {
		if p.type != .Remove { continue; }
		n := leaf_at(t, p.remove_);
		if n == null || n.kind != .Leaf { return ap, .Verify; }
		if p.remove_ == committer { return ap, .Verify; }
		if p.remove_ == g.my_leaf { ap.removed_self = true; }
		n.* = Node.{};
		tree_blank_path(t, p.remove_);
		ap.path_required = true;
	}
	tree_truncate(t);
	// 4. Adds
	for p: props {
		if p.type != .Add { continue; }
		__e9 := validate_key_package(*p.add); if failed(__e9) return ap, __e9;
		for l: 0..n_leaves(t)-1 {
			o := leaf_at(t, l);
			if o.kind == .Leaf && (bytes_equal(o.leaf.signature_key, p.add.leaf.signature_key) || bytes_equal(o.leaf.encryption_key, p.add.leaf.encryption_key)) { return ap, .Verify; }
		}
		idx := tree_add_leaf(t, p.add.leaf, ng.alloc);
		append(*ap.joiners, idx);
		append(*ap.joiner_kps, *p.add);
	}
	// 5. PSKs
	for p: props {
		if p.type == .Psk { append(*ap.psks, p.psk); }
		if p.type == .Reinit || p.type == .External_Init { return ap, .Unsupported; }
	}
	return ap, .None;
}

provisional_context :: (g: *Group, ng: *Group, ap: *Applied) -> Group_Context, []u8 {
	gc: Group_Context;
	bytes: []u8;
	th := root_tree_hash(*ng.tree);
	gc = g.ctx;
	gc.epoch = g.ctx.epoch + 1;
	gc.tree_hash = clone_bytes(view(th), temp);
	if ap.has_new_exts { gc.extensions = ap.new_exts; }
	return gc, group_context_bytes(gc);
}
#scope_export

// ---------------------------------------------------------------------------
// Commit processing (another member's commit)

group_process_commit :: (g: *Group, msg_bytes: []u8) -> *Group, Error {
	res: *Group;
	err: Error;
	ng := group_alloc();
	defer if err != .None { group_destroy(ng); }
	b := clone_bytes(msg_bytes, ng.alloc);
	m, __e10 := parse_mls_message(b, ng.alloc); if failed(__e10) return res, __e10;
	if m.wire_format != .Public_Message { return null, .Unsupported; }
	pm := *m.public;
	fc := *pm.content;
	if fc.content_type != .Commit { return null, .State; }
	if fc.sender.type != .Member { return null, .Unsupported; }
	committer := fc.sender.index;
	if committer == g.my_leaf { return null, .State; } // own commits are adopted, not processed
	__e11 := // own commits are adopted, not processed
	verify_public_message(g, pm); if failed(__e11) return res, __e11;

	// resolve proposals
	props := make_dynamic(*Proposal, 0, len(fc.commit.proposals), temp);
	senders := make_dynamic(Sender, 0, len(fc.commit.proposals), temp);
	for * por: fc.commit.proposals {
		if por.is_ref {
			found := false;
			for * c: g.proposals {
				if bytes_equal(view(c.ref), por.ref) {
					append(*props, *c.proposal);
					append(*senders, c.sender);
					found = true;
					break;
				}
			}
			if !found { return null, .State; }
		} else {
			if por.proposal.type == .Update { return null, .Verify; } // committer cannot inline-update itself
			append(*props, *por.proposal);
			append(*senders, fc.sender);
		}
	}

	__v13, __e12 := copy_tree(*g.tree, ng.alloc); if failed(__e12) return res, __e12; ng.tree = __v13;
	inherit(g, ng);
	for idx, np: g.privs { at(*ng.privs, idx).* = np; }
	ap, __e14 := apply_proposals(g, ng, view(props), view(senders), committer); if failed(__e14) return res, __e14;
	if ap.path_required && !fc.commit.has_path { return null, .Verify; }
	if ap.removed_self { return null, .State; }

	zero: Secret;
	commit_secret := zero;
	if fc.commit.has_path {
		__v16, __e15 := apply_update_path(g, ng, *fc.commit.path, committer, *ap); if failed(__e15) return res, __e15; commit_secret = __v16;
	}

	// new context and key schedule
	gc, _ := provisional_context(g, ng, *ap);
	confirmed := confirmed_hash(view(g.interim), .Public_Message, fc.raw, pm.signature);
	gc.confirmed_transcript_hash = view(confirmed);
	__v18, __e17 := copy_context(gc, ng.alloc); if failed(__e17) return res, __e17; ng.ctx = __v18;
	ctx_bytes := group_context_bytes(ng.ctx);
	psk_secret, __e19 := compute_psk_secret(g, view(ap.psks)); if failed(__e19) return res, __e19;
	psk_slice: []u8 = ifx len(ap.psks) > 0 then view(psk_secret) else null;
	ng.ks = key_schedule(view(g.ks.init), view(commit_secret), psk_slice, ctx_bytes);
	tag := mac(view(ng.ks.confirmation_key), view(confirmed));
	if !bytes_equal(view(tag), pm.confirmation_tag) { return null, .Verify; }
	ng.interim = interim_hash(view(confirmed), view(tag));
	// re-home tree into the new arena (leaves may alias the old group's cache)
	// re-home tree into the new arena (leaves may alias the old group's cache)
	t2, __e20 := copy_tree(*ng.tree, ng.alloc); if failed(__e20) return res, __e20;
	ng.tree = t2;
	prune_privs(ng);
	return ng, .None;
}
#scope_module

// apply_update_path installs the committer's path and decrypts our path secret.
apply_update_path :: (g: *Group, ng: *Group, path: *Update_Path, committer: u32, ap: *Applied) -> Secret, Error {
	commit_secret: Secret;
	err: Error;
	t := *ng.tree;
	if path.leaf.source != .Commit { return commit_secret, .Verify; }
	if !verify_leaf_signature(path.leaf, g.ctx.group_id, committer) { return commit_secret, .Verify; }
	// leaf key must be fresh
	for l: 0..n_leaves(t)-1 {
		if l == committer { continue; }
		o := leaf_at(t, l);
		if o.kind == .Leaf && bytes_equal(o.leaf.encryption_key, path.leaf.encryption_key) { return commit_secret, .Verify; }
	}
	tree_blank_path(t, committer);
	fdp := filtered_direct_path(t, committer);
	if len(fdp) != len(path.nodes) { return commit_secret, .Verify; }
	for x, i: fdp {
		t.nodes[x] = Node.{kind = .Parent, parent = Parent_Node.{encryption_key = path.nodes[i].encryption_key}};
	}
	// parent hashes, top-down
	ph: []u8 = .{};
	cx := committer * 2;
	for < i: len(fdp) - 1..0 {
		p := fdp[i];
		t.nodes[p].parent.parent_hash = ph;
		sib := sibling_of(child_toward(p, cx)); // copath child
		sh := tree_hash(t, sib);
		h := parent_hash_of(t.nodes[p].parent.encryption_key, ph, view(sh));
		ph = clone_bytes(view(h), ng.alloc);
	}
	if !bytes_equal(ph, path.leaf.parent_hash) { return commit_secret, .Verify; }
	leaf_at(t, committer).leaf = path.leaf;

	_, ctx_bytes := provisional_context(g, ng, ap);

	// locate our ciphertext
	me := ng.my_leaf * 2;
	start := -1;
	for x, i: fdp {
		if is_ancestor(x, me) {
			start = i;
			break;
		}
	}
	if start < 0 { return commit_secret, .State; }
	cp := sibling_of(child_toward(fdp[start], cx));
	res := resolution(t, cp);
	k := 0;
	idx := -1;
	priv: [NSK]u8;
	for nr: res {
		if level(nr) == 0 && contains_u32(view(ap.joiners), nr / 2) { continue; }
		{ np, ok := map_find(g.privs, nr);
		if ok {
			cur := node_encryption_key(*t.nodes[nr]);
			pub := np.pub;
			if bytes_equal(cur, view(pub)) {
				idx = k;
				priv = np.priv;
				break;
			}
		} }
		k += 1;
	}
	if idx < 0 || idx >= len(path.nodes[start].secrets) { return commit_secret, .State; }
	ps, dok := decrypt_with_label(view(priv), "UpdatePathNode", ctx_bytes, get(path.nodes[start].secrets, idx), temp);
	if !dok || len(ps) != NH { return commit_secret, .Crypto; }
	cur: Secret;
	copy(view(cur), ps);
	for i: start..len(fdp)-1 {
		ns := derive_secret(view(cur), "node");
		kp, kok := derive_key_pair(view(ns));
		if !kok { return commit_secret, .Crypto; }
		if !bytes_equal(view(kp.pub), path.nodes[i].encryption_key) { return commit_secret, .Verify; }
		at(*ng.privs, fdp[i]).* = Node_Priv.{kp.priv, kp.pub};
		cur = derive_secret(view(cur), "path");
	}
	return cur, .None;
}
#scope_export

// ---------------------------------------------------------------------------
// Commit creation

Commit_Result :: struct {
	commit: []u8; // MLSMessage (PublicMessage)
	welcome: []u8; // Welcome (raw struct, as DAVE sends it); nil without adds
	has_welcome: bool;
	group: *Group; // the next epoch's state, adopt once the commit is accepted
}

// group_commit commits every cached proposal by reference (libdave behaviour:
// inline ratchet tree in the GroupInfo, path only when required).
group_commit :: (g: *Group, force_path := false, allocator := context.allocator) -> Commit_Result, Error {
	res: Commit_Result;
	err: Error;
	ng := group_alloc();
	defer if err != .None { group_destroy(ng); }

	props := make_dynamic(*Proposal, 0, len(g.proposals), temp);
	senders := make_dynamic(Sender, 0, len(g.proposals), temp);
	refs := make_dynamic(Proposal_Or_Ref, 0, len(g.proposals), temp);
	for * c: g.proposals {
		append(*props, *c.proposal);
		append(*senders, c.sender);
		append(*refs, Proposal_Or_Ref.{is_ref = true, ref = view(c.ref)});
	}
	__v22, __e21 := copy_tree(*g.tree, ng.alloc); if failed(__e21) return res, __e21; ng.tree = __v22;
	inherit(g, ng);
	for idx, np: g.privs { at(*ng.privs, idx).* = np; }
	ap, __e23 := apply_proposals(g, ng, view(props), view(senders), g.my_leaf); if failed(__e23) return res, __e23;
	if ap.removed_self { return res, .State; }
	t := *ng.tree;
	commit := Commit.{proposals = view(refs)};
	zero: Secret;
	commit_secret := zero;
	path_secrets := make_dynamic(Secret, 0, 8, temp);
	fdp: []u32;
	if ap.path_required || force_path {
		commit.has_path = true;
		leaf_secret: Secret;
		crypto.rand_bytes(view(leaf_secret));
		lns := derive_secret(view(leaf_secret), "node");
		leaf_kp, ok := derive_key_pair(view(lns));
		if !ok { return res, .Crypto; }
		tree_blank_path(t, g.my_leaf);
		fdp = filtered_direct_path(t, g.my_leaf);
		cur := derive_secret(view(leaf_secret), "path");
		nodes := make_slice(Update_Path_Node, len(fdp), temp);
		for x, i: fdp {
			append(*path_secrets, cur);
			ns := derive_secret(view(cur), "node");
			kp, ok2 := derive_key_pair(view(ns));
			if !ok2 { return res, .Crypto; }
			t.nodes[x] = Node.{kind = .Parent, parent = Parent_Node.{encryption_key = clone_bytes(view(kp.pub), ng.alloc)}};
			at(*ng.privs, x).* = Node_Priv.{kp.priv, kp.pub};
			nodes[i].encryption_key = t.nodes[x].parent.encryption_key;
			cur = derive_secret(view(cur), "path");
		}
		commit_secret = cur;
		ph: []u8 = .{};
		mx := g.my_leaf * 2;
		for < i: len(fdp) - 1..0 {
			p := fdp[i];
			t.nodes[p].parent.parent_hash = ph;
			sib := sibling_of(child_toward(p, mx));
			sh := tree_hash(t, sib);
			h := parent_hash_of(t.nodes[p].parent.encryption_key, ph, view(sh));
			ph = clone_bytes(view(h), ng.alloc);
		}
		old_leaf := leaf_at(*g.tree, g.my_leaf).leaf;
		nl := old_leaf;
		nl.encryption_key = clone_bytes(view(leaf_kp.pub), ng.alloc);
		nl.source = .Commit;
		nl.parent_hash = ph;
		nl.not_before = 0;
		nl.not_after = 0;
		sig, sok := sign_with_label(view(g.sig_priv), "LeafNodeTBS", leaf_node_tbs(nl, g.ctx.group_id, g.my_leaf), ng.alloc);
		if !sok { return res, .Crypto; }
		nl.signature = sig;
		leaf_at(t, g.my_leaf).leaf = nl;
		at(*ng.privs, mx).* = Node_Priv.{leaf_kp.priv, leaf_kp.pub};
		_, ctx_bytes := provisional_context(g, ng, *ap);
		for x, i: fdp {
			cp := sibling_of(child_toward(x, mx));
			res_nodes := resolution(t, cp);
			cts := make_dynamic(Hpke_Ciphertext, 0, len(res_nodes), temp);
			for nr: res_nodes {
				if level(nr) == 0 && contains_u32(view(ap.joiners), nr / 2) { continue; }
				ct, eok := encrypt_with_label(node_encryption_key(*t.nodes[nr]), "UpdatePathNode", ctx_bytes, view(path_secrets[i]), temp);
				if !eok { return res, .Crypto; }
				append(*cts, ct);
			}
			nodes[i].secrets = view(cts);
		}
		commit.path = Update_Path.{leaf = nl, nodes = nodes};
	}

	fc := Framed_Content.{
		group_id = g.ctx.group_id,
		epoch = g.ctx.epoch,
		sender = Sender.{.Member, g.my_leaf},
		content_type = .Commit,
		commit = commit
	};
	content_raw := framed_content_bytes(fc);
	old_ctx_bytes := group_context_bytes(g.ctx);
	tbs := framed_content_tbs(content_raw, fc.sender, old_ctx_bytes);
	signature, sok := sign_with_label(view(g.sig_priv), "FramedContentTBS", tbs, temp);
	if !sok { return res, .Crypto; }

	gc, _ := provisional_context(g, ng, *ap);
	confirmed := confirmed_hash(view(g.interim), .Public_Message, content_raw, signature);
	gc.confirmed_transcript_hash = view(confirmed);
	__v25, __e24 := copy_context(gc, ng.alloc); if failed(__e24) return res, __e24; ng.ctx = __v25;
	ctx_bytes := group_context_bytes(ng.ctx);
	psk_secret, __e26 := compute_psk_secret(g, view(ap.psks)); if failed(__e26) return res, __e26;
	psk_slice: []u8 = ifx len(ap.psks) > 0 then view(psk_secret) else null;
	ng.ks = key_schedule(view(g.ks.init), view(commit_secret), psk_slice, ctx_bytes);
	tag := mac(view(ng.ks.confirmation_key), view(confirmed));
	ng.interim = interim_hash(view(confirmed), view(tag));

	tbm := writer_make();
	w_raw(*tbm, tbs);
	w_raw(*tbm, auth_data_bytes(signature, view(tag), true));
	mtag := mac(view(g.ks.membership_key), view(tbm.buf));

	w := writer_make(allocator);
	w_u16(*w, PROTOCOL_VERSION);
	w_u16(*w, cast(u16)(Wire_Format.Public_Message));
	w_raw(*w, content_raw);
	w_vec(*w, signature);
	w_vec(*w, view(tag));
	w_vec(*w, view(mtag));
	res.commit = view(w.buf);

	if len(ap.joiners) > 0 {
		__v28, __e27 := build_welcome(g, ng, *ap, fdp, view(path_secrets), view(tag), allocator); if failed(__e27) return res, __e27; res.welcome = __v28;
		res.has_welcome = true;
	}
	__v30, __e29 := copy_tree(*ng.tree, ng.alloc); if failed(__e29) return res, __e29; ng.tree = __v30;
	prune_privs(ng);
	res.group = ng;
	return res, .None;
}
#scope_module

build_welcome :: (g: *Group, ng: *Group, ap: *Applied, fdp: []u32, path_secrets: []Secret, conf_tag: []u8, allocator: Allocator) -> []u8, Error {
	out: []u8;
	err: Error;
	ext_kp, ok := derive_key_pair(view(ng.ks.external));
	if !ok { return .{}, .Crypto; }
	ep := writer_make();
	w_vec(*ep, view(ext_kp.pub));
	rt := ratchet_tree_bytes(*ng.tree);
	exts := Extension.[.{EXT_EXTERNAL_PUB, view(ep.buf)}, .{EXT_RATCHET_TREE, rt}];
	gi := Group_Info.{
		ctx = ng.ctx,
		extensions = exts,
		confirmation_tag = conf_tag,
		signer = g.my_leaf
	};
	sig, sok := sign_with_label(view(g.sig_priv), "GroupInfoTBS", group_info_tbs(gi), temp);
	if !sok { return .{}, .Crypto; }
	giw := writer_make();
	w_raw(*giw, group_info_tbs(gi));
	w_vec(*giw, sig);
	key, nonce := welcome_key_nonce(view(ng.ks.welcome));
	egi := aead_seal(view(key), view(nonce), null, view(giw.buf), temp);

	secrets := make_dynamic(Encrypted_Group_Secrets, 0, len(ap.joiners), temp);
	for j, ji: ap.joiners {
		kp := ap.joiner_kps[ji];
		gs := writer_make();
		w_vec(*gs, view(ng.ks.joiner));
		ps_idx := -1;
		for x, i: fdp { if is_ancestor(x, j * 2) {
			ps_idx = i;
			break;
		} }
		w_optional(*gs, ps_idx >= 0);
		if ps_idx >= 0 { w_vec(*gs, view(path_secrets[ps_idx])); }
		pp := w_begin(*gs);
		for p: ap.psks { w_psk_id(*gs, p); }
		w_end(*gs, pp);
		ct, eok := encrypt_with_label(kp.init_key, "Welcome", egi, view(gs.buf), temp);
		if !eok { return .{}, .Crypto; }
		ref := key_package_ref(kp.raw);
		append(*secrets, Encrypted_Group_Secrets.{new_member = clone_bytes(view(ref), temp), secrets = ct});
	}
	wel := Welcome.{
		cipher_suite = CIPHER_SUITE,
		secrets = view(secrets),
		encrypted_group_info = egi
	};
	w := writer_make(allocator);
	w_welcome(*w, wel);
	return view(w.buf), .None;
}
#scope_export

// ---------------------------------------------------------------------------
// Joining from a Welcome

Join_Params :: struct {
	key_package: *Key_Package;
	secrets: *Key_Package_Secrets;
	sig_priv: [NSK]u8;
	ratchet_tree: []u8; // out-of-band tree when the GroupInfo has none
	ext_psks: []Psk_Entry;
}

group_join :: (welcome_bytes: []u8, p: Join_Params) -> *Group, Error {
	res: *Group;
	err: Error;
	ng := group_alloc();
	defer if err != .None { group_destroy(ng); }
	a := ng.alloc;
	for e: p.ext_psks { group_add_external_psk(ng, e.id, e.secret); }
	b := clone_bytes(welcome_bytes, a);
	r := reader_make(b);
	wel := r_welcome(*r, a);
	if !r_done(*r) { return null, .Decode; }
	if wel.cipher_suite != CIPHER_SUITE { return null, .Unsupported; }
	my_ref := key_package_ref(p.key_package.raw);
	egs: *Encrypted_Group_Secrets;
	for * e: wel.secrets { if bytes_equal(e.new_member, view(my_ref)) { egs = *e; } }
	if egs == null { return null, .State; }
	gs_bytes, ok := decrypt_with_label(view(p.secrets.init_priv), "Welcome", wel.encrypted_group_info, egs.secrets, a);
	if !ok { return null, .Crypto; }
	gr := reader_make(gs_bytes);
	gs := r_group_secrets(*gr, a);
	if !r_done(*gr) || len(gs.joiner_secret) != NH { return null, .Decode; }

	// psk secret: computed against an empty group (external PSKs only)
	// psk secret: computed against an empty group (external PSKs only)
	psk_secret, __e31 := compute_psk_secret(ng, gs.psks); if failed(__e31) return res, __e31;
	copy(view(ng.ks.joiner), gs.joiner_secret);
	zero: Secret;
	psk_slice := ifx len(gs.psks) > 0 then view(psk_secret) else view(zero);
	m := kdf_extract(view(ng.ks.joiner), psk_slice);
	ng.ks.welcome = derive_secret(view(m), "welcome");
	key, nonce := welcome_key_nonce(view(ng.ks.welcome));
	gi_bytes, ok2 := aead_open(view(key), view(nonce), null, wel.encrypted_group_info, a);
	if !ok2 { return null, .Crypto; }
	ir := reader_make(gi_bytes);
	gi := r_group_info(*ir, a);
	if !r_done(*ir) { return null, .Decode; }
	if gi.ctx.cipher_suite != CIPHER_SUITE || gi.ctx.version != PROTOCOL_VERSION { return null, .Unsupported; }

	tree_bytes := p.ratchet_tree;
	{ e, has := find_extension(gi.extensions, EXT_RATCHET_TREE);
	if has { tree_bytes = e.data; } }
	if tree_bytes == null { return null, .State; }
	__v33, __e32 := parse_ratchet_tree(clone_bytes(tree_bytes, a), a); if failed(__e32) return res, __e32; ng.tree = __v33;
	t := *ng.tree;

	signer, sok := member_leaf(ng, gi.signer);
	if !sok { return null, .Verify; }
	if !verify_with_label(signer.signature_key, "GroupInfoTBS", group_info_tbs(gi), gi.signature) { return null, .Verify; }
	__e34 := tree_validate(t, gi.ctx.group_id, gi.ctx.tree_hash); if failed(__e34) return res, __e34;

	// find our leaf
	found := false;
	for l: 0..n_leaves(t)-1 {
		n := leaf_at(t, l);
		if n.kind == .Leaf && bytes_equal(n.leaf.encryption_key, p.key_package.leaf.encryption_key) && bytes_equal(n.leaf.signature_key, p.key_package.leaf.signature_key) {
			ng.my_leaf = l;
			found = true;
			break;
		}
	}
	if !found { return null, .State; }
	ng.sig_priv = p.sig_priv;
	lp, _ := public_from_private(view(p.secrets.leaf_priv));
	at(*ng.privs, ng.my_leaf * 2).* = Node_Priv.{p.secrets.leaf_priv, lp};

	if gs.has_path_secret {
		if len(gs.path_secret) != NH { return null, .Decode; }
		lca := common_ancestor(ng.my_leaf * 2, gi.signer * 2);
		fdp := filtered_direct_path(t, gi.signer);
		cur: Secret;
		copy(view(cur), gs.path_secret);
		started := false;
		for x: fdp {
			if x == lca { started = true; }
			if !started { continue; }
			ns := derive_secret(view(cur), "node");
			kp, kok := derive_key_pair(view(ns));
			if !kok { return null, .Crypto; }
			if !bytes_equal(view(kp.pub), node_encryption_key(*t.nodes[x])) { return null, .Verify; }
			at(*ng.privs, x).* = Node_Priv.{kp.priv, kp.pub};
			cur = derive_secret(view(cur), "path");
		}
		if !started { return null, .Verify; }
	}

	ng.ctx = gi.ctx;
	ctx_bytes := group_context_bytes(ng.ctx);
	expand_with_label(view(m), "epoch", ctx_bytes, view(ng.ks.epoch));
	key_schedule_from_epoch(*ng.ks);
	tag := mac(view(ng.ks.confirmation_key), ng.ctx.confirmed_transcript_hash);
	if !bytes_equal(view(tag), gi.confirmation_tag) { return null, .Verify; }
	ng.interim = interim_hash(ng.ctx.confirmed_transcript_hash, gi.confirmation_tag);
	return ng, .None;
}

// ---------------------------------------------------------------------------
// External sender messages (used by the voice gateway; here for tests/fakes)

external_proposal :: (group_id: []u8, ep: u64, sender_index: u32, prop: Proposal, sig_priv: []u8, allocator := context.allocator) -> []u8, bool {
	fc := Framed_Content.{
		group_id = group_id,
		epoch = ep,
		sender = Sender.{.External, sender_index},
		content_type = .Proposal,
		proposal = prop
	};
	raw := framed_content_bytes(fc);
	sig, ok := sign_with_label(sig_priv, "FramedContentTBS", framed_content_tbs(raw, fc.sender, null), temp);
	if !ok { return .{}, false; }
	w := writer_make(allocator);
	w_u16(*w, PROTOCOL_VERSION);
	w_u16(*w, cast(u16)(Wire_Format.Public_Message));
	w_raw(*w, raw);
	w_vec(*w, sig);
	return view(w.buf), true;
}

// leaf index of the member whose basic credential identity equals id.
find_member :: (g: *Group, identity: []u8) -> u32, bool {
	for l: 0..(n_leaves(*g.tree))-1 {
		n := leaf_at(*g.tree, l);
		if n.kind == .Leaf && bytes_equal(n.leaf.credential.data, identity) { return l, true; }
	}
	return 0, false;
}

#scope_file static_versions6 := u16.[PROTOCOL_VERSION]; #scope_export
#scope_file static_suites7 := u16.[CIPHER_SUITE]; #scope_export
#scope_file static_creds8 := u16.[CRED_BASIC]; #scope_export

