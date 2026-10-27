// Group: one epoch of MLS group state. Every state transition (commit,
// welcome) produces a NEW Group with its own pool, leaving the old one
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
	pool: Flat_Pool;
	alloc: Allocator;  // everything the group holds lives in pool
	ctx: Group_Context;
	tree: Tree;
	my_leaf: u32;
	sig_priv: [NSK]u8;
	privs: Table(u32, Node_Priv);  // node index -> private key
	interim: Secret;
	ks: Epoch_Secrets;
	proposals: [..]Cached_Proposal;
	ext_psks: [..]Psk_Entry;
	resumption: [..]Resumption_Entry; // previous epochs (most recent last)
}

group_alloc :: () -> *Group {
	g := New(Group);
	g.alloc = .{flat_pool_allocator_proc, *g.pool};
	g.privs.allocator = g.alloc;
	g.tree.nodes.allocator = g.alloc;
	g.proposals.allocator = g.alloc;
	g.ext_psks.allocator = g.alloc;
	g.resumption.allocator = g.alloc;
	return g;
}

group_destroy :: (g: *Group) {
	if !g return;
	crypto.zero(*g.ks);
	crypto.zero(*g.sig_priv);
	fini(*g.pool);
	free(g);
}

group_add_external_psk :: (g: *Group, id: []u8, secret: []u8) {
	push_allocator(g.alloc);
	array_add(*g.ext_psks, .{clone_bytes(id), clone_bytes(secret)});
}

epoch :: (g: *Group) -> u64 { return g.ctx.epoch; }
group_id :: (g: *Group) -> []u8 { return g.ctx.group_id; }
epoch_authenticator :: (g: *Group) -> Secret { return g.ks.epoch_authenticator; }

// exporter: MLS-Exporter(label, context, length) (RFC 9420 8.5).
exporter :: (g: *Group, label: string, ctx: []u8, dst: []u8) {
	s := derive_secret(g.ks.exporter, label);
	h := hash_bytes(ctx);
	expand_with_label(s, "exported", h, dst);
}

member_leaf :: (g: *Group, leaf: u32) -> *Leaf_Node {
	n := leaf_at(*g.tree, leaf);
	if !n || n.kind != .Leaf return null;
	return *n.leaf;
}

// ---------------------------------------------------------------------------
// Key schedule

key_schedule_from_epoch :: (ks: *Epoch_Secrets) {
	e := ks.epoch;
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
	expand_with_label(x, "joiner", ctx_bytes, ks.joiner);
	zero: Secret;
	m := kdf_extract(ks.joiner, ifx psk_secret.count then psk_secret else zero);
	ks.welcome = derive_secret(m, "welcome");
	expand_with_label(m, "epoch", ctx_bytes, ks.epoch);
	key_schedule_from_epoch(*ks);
	return ks;
}

welcome_key_nonce :: (welcome_secret: []u8) -> [NK]u8, [NN]u8 {
	key: [NK]u8;
	nonce: [NN]u8;
	expand_with_label(welcome_secret, "key", .[], key);
	expand_with_label(welcome_secret, "nonce", .[], nonce);
	return key, nonce;
}

// compute_psk_secret: psk_secret (RFC 9420 8.4) from the group's external and resumption PSKs.
compute_psk_secret :: (g: *Group, psks: []Psk_Id) -> Secret, Error {
	acc: Secret;
	for p, i: psks {
		value: []u8;
		if p.type == {
		case 1;
			for g.ext_psks if bytes_equal(it.id, p.id) value = it.secret;
		case 2;
			if p.usage != 1 return acc, .Unsupported; // only "application" resumption
			if !bytes_equal(p.group_id, g.ctx.group_id) return acc, .Unsupported;
			if p.epoch == g.ctx.epoch {
				value = g.ks.resumption_psk;
			} else {
				for * g.resumption if it.epoch == p.epoch value = it.secret;
			}
		}
		if !value.data return acc, .State;
		extracted := kdf_extract(.[], value);
		w := writer_make();
		w_psk_id(*w, p);
		w_u16(*w, cast(u16) i);
		w_u16(*w, cast(u16) psks.count);
		input: Secret;
		expand_with_label(extracted, "derived psk", w.buf, input);
		acc = kdf_extract(input, acc);
	}
	return acc, .None;
}

// ---------------------------------------------------------------------------
// Transcript hashes

confirmed_hash :: (interim: []u8, wire_format: Wire_Format, content_raw: []u8, signature: []u8) -> Secret {
	w := writer_make();
	w_raw(*w, interim);
	w_u16(*w, cast(u16) wire_format);
	w_raw(*w, content_raw);
	w_vec(*w, signature);
	return hash_bytes(w.buf);
}

interim_hash :: (confirmed: []u8, confirmation_tag: []u8) -> Secret {
	w := writer_make();
	w_raw(*w, confirmed);
	w_vec(*w, confirmation_tag);
	return hash_bytes(w.buf);
}

// ---------------------------------------------------------------------------
// Framing helpers

framed_content_tbs :: (content_raw: []u8, sender: Sender, ctx_bytes: []u8) -> []u8 {
	w := writer_make();
	w_u16(*w, PROTOCOL_VERSION);
	w_u16(*w, cast(u16) Wire_Format.Public_Message);
	w_raw(*w, content_raw);
	if sender.type == .Member || sender.type == .New_Member_Commit w_raw(*w, ctx_bytes);
	return w.buf;
}

// w_auth_data: FramedContentAuthData.
w_auth_data :: (w: *Writer, signature: []u8, confirmation_tag: []u8, is_commit: bool) {
	w_vec(w, signature);
	if is_commit w_vec(w, confirmation_tag);
}

// membership_tag: MAC over FramedContentTBS || FramedContentAuthData.
membership_tag :: (key: []u8, tbs: []u8, signature: []u8, confirmation_tag: []u8, is_commit: bool) -> Secret {
	w := writer_make();
	w_raw(*w, tbs);
	w_auth_data(*w, signature, confirmation_tag, is_commit);
	return mac(key, w.buf);
}

// proposal_ref: RefHash over AuthenticatedContent (wire_format || FramedContent || FramedContentAuthData).
proposal_ref :: (content_raw: []u8, signature: []u8) -> Secret {
	w := writer_make();
	w_u16(*w, cast(u16) Wire_Format.Public_Message);
	w_raw(*w, content_raw);
	w_auth_data(*w, signature, .[], false);
	return ref_hash("MLS 1.0 Proposal Reference", w.buf);
}

key_package_ref :: (kp_raw: []u8) -> Secret { return ref_hash("MLS 1.0 KeyPackage Reference", kp_raw); }

// external_senders: the group's external_senders extension, in temp.
external_senders :: (g: *Group) -> []External_Sender {
	e, ok := find_extension(g.ctx.extensions, EXT_EXTERNAL_SENDERS);
	out: [..]External_Sender;
	out.allocator = temp;
	if !ok return out;
	r := reader_make(e.data);
	sub := r_sub(*r);
	while r_ok(*sub) && r_left(*sub) > 0 array_add(*out, r_external_sender(*sub));
	return out;
}

// external_senders_extension encodes the extension in temp.
external_senders_extension :: (senders: []External_Sender) -> Extension {
	w := writer_make();
	p := w_begin(*w);
	for senders w_external_sender(*w, it);
	w_end(*w, p);
	return .{EXT_EXTERNAL_SENDERS, w.buf};
}

// verify_public_message: epoch / group checks, signature and membership tag.
verify_public_message :: (g: *Group, pm: *Public_Message) -> Error {
	fc := *pm.content;
	if !bytes_equal(fc.group_id, g.ctx.group_id) || fc.epoch != g.ctx.epoch return .State;
	sig_key: []u8;
	if fc.sender.type == {
	case .Member;
		ln := member_leaf(g, fc.sender.index);
		if !ln return .State;
		sig_key = ln.signature_key;
	case .External;
		es := external_senders(g);
		if cast(int) fc.sender.index >= es.count return .State;
		sig_key = es[fc.sender.index].signature_key;
	case;
		return .Unsupported;
	}
	tbs := framed_content_tbs(fc.raw, fc.sender, group_context_bytes(g.ctx));
	if !verify_with_label(sig_key, "FramedContentTBS", tbs, pm.signature) return .Verify;
	if fc.sender.type == .Member {
		tag := membership_tag(g.ks.membership_key, tbs, pm.signature, pm.confirmation_tag, fc.content_type == .Commit);
		if !bytes_equal(tag, pm.membership_tag) return .Verify;
	}
	return .None;
}

validate_key_package :: (kp: *Key_Package) -> Error {
	if kp.version != PROTOCOL_VERSION || kp.cipher_suite != CIPHER_SUITE return .Unsupported;
	if kp.leaf.source != .Key_Package return .Verify;
	if bytes_equal(kp.init_key, kp.leaf.encryption_key) return .Verify;
	if !verify_with_label(kp.leaf.signature_key, "KeyPackageTBS", key_package_tbs(kp), kp.signature) return .Verify;
	if !verify_leaf_signature(kp.leaf, .[], 0) return .Verify;
	return .None;
}

// group_cache_proposal verifies and caches a proposal (PublicMessage bytes).
// Returns the cached proposal ref.
group_cache_proposal :: (g: *Group, msg_bytes: []u8) -> Secret, *Cached_Proposal, Error {
	ref: Secret;
	push_allocator(g.alloc);
	m, err := parse_mls_message(clone_bytes(msg_bytes));
	if err != .None return ref, null, err;
	if m.wire_format != .Public_Message return ref, null, .Unsupported;
	pm := *m.public;
	if pm.content.content_type != .Proposal return ref, null, .State;
	err = verify_public_message(g, pm);
	if err != .None return ref, null, err;
	ref = proposal_ref(pm.content.raw, pm.signature);
	for * g.proposals if bytes_equal(it.ref, ref) return ref, it, .None;
	if pm.content.proposal.type == .Add {
		err = validate_key_package(*pm.content.proposal.add);
		if err != .None return ref, null, err;
	}
	array_add(*g.proposals, .{ref = ref, proposal = pm.content.proposal, sender = pm.content.sender});
	return ref, *g.proposals[g.proposals.count - 1], .None;
}

group_revoke_proposal :: (g: *Group, ref: []u8) -> bool {
	for g.proposals if bytes_equal(it.ref, ref) {
		array_ordered_remove_by_index(*g.proposals, it_index);
		return true;
	}
	return false;
}

// ---------------------------------------------------------------------------
// Rebase: deep copy the tree / context into context.allocator (the new group's
// pool) by serializing and re-parsing.

copy_tree :: (t: *Tree) -> Tree, Error {
	if !t.nodes.count return .{}, .State;
	out, err := parse_ratchet_tree(clone_bytes(ratchet_tree_bytes(t)));
	if err != .None return out, err;
	// preserve full width (parse trims to the minimal full tree)
	if out.nodes.count < t.nodes.count array_resize(*out.nodes, t.nodes.count);
	return out, .None;
}

copy_context :: (gc: Group_Context) -> Group_Context, Error {
	r := reader_make(clone_bytes(group_context_bytes(gc)));
	out := r_group_context(*r);
	return out, ifx r_done(*r) then .None else .Decode;
}

// inherit: what the next epoch's group ng keeps from g.
inherit :: (g: *Group, ng: *Group) {
	ng.my_leaf = g.my_leaf;
	ng.sig_priv = g.sig_priv;
	for g.ext_psks group_add_external_psk(ng, it.id, it.secret);
	array_add(*ng.resumption, ..g.resumption);
	array_add(*ng.resumption, .{g.ctx.epoch, g.ks.resumption_psk});
	if ng.resumption.count > 16 array_ordered_remove_by_index(*ng.resumption, 0);
	for np, idx: g.privs table_set(*ng.privs, idx, np);
}

// prune_privs drops private keys whose node changed.
prune_privs :: (g: *Group) {
	stale: [..]u32;
	stale.allocator = temp;
	for np, idx: g.privs {
		if cast(int) idx >= g.tree.nodes.count || !bytes_equal(node_encryption_key(*g.tree.nodes[idx]), np.pub) array_add(*stale, idx);
	}
	for stale table_remove(*g.privs, it);
}

// ---------------------------------------------------------------------------
// Creation & key packages

Key_Package_Secrets :: struct {
	init_priv: [NSK]u8;
	leaf_priv: [NSK]u8;
}

// key_package_create builds a signed KeyPackage the way libdave does:
// basic credential, lifetime [0, 2^64-1], no extensions. Returns the
// KeyPackage (serialized as an MLSMessage, in context.allocator, as are the
// KeyPackage's fields) and its private keys.
key_package_create :: (id: *Identity) -> []u8, Key_Package, Key_Package_Secrets {
	kp: Key_Package;
	secrets: Key_Package_Secrets;
	init := generate_key_pair();
	leaf := generate_key_pair();
	secrets.init_priv = init.priv;
	secrets.leaf_priv = leaf.priv;
	kp.version = PROTOCOL_VERSION;
	kp.cipher_suite = CIPHER_SUITE;
	kp.init_key = clone_bytes(init.pub);
	kp.leaf = .{
		encryption_key = clone_bytes(leaf.pub),
		signature_key = clone_bytes(id.sig_pub),
		credential = .{id.credential.type, clone_bytes(id.credential.data)},
		capabilities = .{versions = default_versions, cipher_suites = default_suites, credentials = default_credentials},
		source = .Key_Package,
		not_before = 0,
		not_after = 0xFFFF_FFFF_FFFF_FFFF
	};
	ok: bool;
	kp.leaf.signature, ok = sign_with_label(id.sig_priv, "LeafNodeTBS", leaf_node_tbs(kp.leaf, .[], 0));
	assert(ok);
	kp.signature, ok = sign_with_label(id.sig_priv, "KeyPackageTBS", key_package_tbs(kp));
	assert(ok);
	w := writer_make(context.allocator);
	w_u16(*w, PROTOCOL_VERSION);
	w_u16(*w, cast(u16) Wire_Format.Key_Package);
	w_key_package(*w, kp);
	kp.raw = array_view(w.buf, 4);
	return w.buf, kp, secrets;
}

// group_create: a one-member group at epoch 0 using the leaf from our key package.
group_create :: (gid: []u8, id: *Identity, kp: *Key_Package, secrets: *Key_Package_Secrets, extensions: []Extension) -> *Group, Error {
	g := group_alloc();
	push_allocator(g.alloc);
	g.sig_priv = id.sig_priv;
	r := reader_make(clone_bytes(kp.raw));
	kp2 := r_key_package(*r);
	if !r_done(*r) {
		group_destroy(g);
		return null, .Decode;
	}
	array_add(*g.tree.nodes, .{kind = .Leaf, leaf = kp2.leaf});
	g.my_leaf = 0;
	lp := public_from_private(secrets.leaf_priv);
	table_set(*g.privs, 0, .{secrets.leaf_priv, lp});
	th := root_tree_hash(*g.tree);
	err: Error;
	g.ctx, err = copy_context(.{version = PROTOCOL_VERSION, cipher_suite = CIPHER_SUITE, group_id = gid, tree_hash = th, extensions = extensions});
	if err != .None {
		group_destroy(g);
		return null, err;
	}
	crypto.random_bytes(g.ks.epoch);
	key_schedule_from_epoch(*g.ks);
	tag := mac(g.ks.confirmation_key, .[]);
	g.interim = interim_hash(.[], tag);
	return g, .None;
}

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

// apply_proposals applies props to ng's tree (in RFC 9420 12.3 order).
apply_proposals :: (g: *Group, ng: *Group, props: []*Proposal, senders: []Sender, committer: u32) -> Applied, Error {
	ap: Applied;
	ap.joiners.allocator = temp;
	ap.joiner_kps.allocator = temp;
	ap.psks.allocator = temp;
	ap.path_required = props.count == 0;
	t := *ng.tree;
	// 1. GroupContextExtensions
	for p: props if p.type == .Group_Context_Extensions {
		if ap.has_new_exts return ap, .Verify;
		ap.new_exts = p.extensions;
		ap.has_new_exts = true;
		ap.path_required = true;
	}
	// 2. Updates
	for p: props {
		if p.type != .Update continue;
		s := senders[it_index];
		if s.type != .Member || s.index == committer || p.update.source != .Update return ap, .Verify;
		if !verify_leaf_signature(p.update, g.ctx.group_id, s.index) return ap, .Verify;
		n := leaf_at(t, s.index);
		if !n || n.kind != .Leaf return ap, .Verify;
		n.leaf = p.update;
		tree_blank_path(t, s.index);
		ap.path_required = true;
	}
	// 3. Removes
	for p: props {
		if p.type != .Remove continue;
		n := leaf_at(t, p.remove_);
		if !n || n.kind != .Leaf || p.remove_ == committer return ap, .Verify;
		if p.remove_ == g.my_leaf ap.removed_self = true;
		n.* = .{};
		tree_blank_path(t, p.remove_);
		ap.path_required = true;
	}
	tree_truncate(t);
	// 4. Adds
	for p: props {
		if p.type != .Add continue;
		err := validate_key_package(*p.add);
		if err != .None return ap, err;
		for l: 0..cast(s64) n_leaves(t) - 1 {
			o := leaf_at(t, cast(u32) l);
			if o.kind == .Leaf && (bytes_equal(o.leaf.signature_key, p.add.leaf.signature_key) || bytes_equal(o.leaf.encryption_key, p.add.leaf.encryption_key)) return ap, .Verify;
		}
		array_add(*ap.joiners, tree_add_leaf(t, p.add.leaf));
		array_add(*ap.joiner_kps, *p.add);
	}
	// 5. PSKs
	for p: props {
		if p.type == .Psk array_add(*ap.psks, p.psk);
		if p.type == .Reinit || p.type == .External_Init return ap, .Unsupported;
	}
	return ap, .None;
}

// provisional_context: the next epoch's GroupContext before the transcript hash.
provisional_context :: (g: *Group, ng: *Group, ap: *Applied) -> Group_Context {
	th := root_tree_hash(*ng.tree);
	gc := g.ctx;
	gc.epoch = g.ctx.epoch + 1;
	gc.tree_hash = array_copy(th,, temp);
	if ap.has_new_exts gc.extensions = ap.new_exts;
	return gc;
}

// set_parent_hashes fills in parent hashes top-down along fdp and returns the leaf's parent hash.
set_parent_hashes :: (t: *Tree, fdp: []u32, leaf: u32) -> []u8 {
	ph: []u8;
	for < fdp {
		t.nodes[it].parent.parent_hash = ph;
		sh := tree_hash(t, sibling_of(child_toward(it, leaf * 2))); // copath child
		h := parent_hash_of(t.nodes[it].parent.encryption_key, ph, sh);
		ph = clone_bytes(h);
	}
	return ph;
}

// next_epoch: the new context with its transcript hash, key schedule and interim hash for ng.
// Returns the confirmation tag.
next_epoch :: (g: *Group, ng: *Group, ap: *Applied, content_raw: []u8, signature: []u8, commit_secret: []u8) -> Secret, Error {
	gc := provisional_context(g, ng, ap);
	confirmed := confirmed_hash(g.interim, .Public_Message, content_raw, signature);
	gc.confirmed_transcript_hash = confirmed;
	err: Error;
	ng.ctx, err = copy_context(gc);
	if err != .None return ZERO_SECRET, err;
	psk_secret: Secret;
	psk_secret, err = compute_psk_secret(g, ap.psks);
	if err != .None return ZERO_SECRET, err;
	ng.ks = key_schedule(g.ks.init, commit_secret, ifx ap.psks.count then cast([]u8) psk_secret else .[], group_context_bytes(ng.ctx));
	tag := mac(ng.ks.confirmation_key, confirmed);
	ng.interim = interim_hash(confirmed, tag);
	return tag, .None;
}

// ---------------------------------------------------------------------------
// Commit processing (another member's commit)

group_process_commit :: (g: *Group, msg_bytes: []u8) -> *Group, Error {
	ng := group_alloc();
	err := process_commit(g, ng, msg_bytes);
	if err != .None {
		group_destroy(ng);
		return null, err;
	}
	return ng, .None;
}

process_commit :: (g: *Group, ng: *Group, msg_bytes: []u8) -> Error {
	push_allocator(ng.alloc);
	m, err := parse_mls_message(clone_bytes(msg_bytes));
	if err != .None return err;
	if m.wire_format != .Public_Message return .Unsupported;
	pm := *m.public;
	fc := *pm.content;
	if fc.content_type != .Commit return .State;
	if fc.sender.type != .Member return .Unsupported;
	committer := fc.sender.index;
	if committer == g.my_leaf return .State; // own commits are adopted, not processed
	err = verify_public_message(g, pm);
	if err != .None return err;

	// resolve proposals
	props: [..]*Proposal;
	senders: [..]Sender;
	props.allocator, senders.allocator = temp, temp;
	for * por: fc.commit.proposals {
		if por.is_ref {
			found := false;
			for * c: g.proposals if bytes_equal(c.ref, por.ref) {
				array_add(*props, *c.proposal);
				array_add(*senders, c.sender);
				found = true;
				break;
			}
			if !found return .State;
		} else {
			if por.proposal.type == .Update return .Verify; // committer cannot inline-update itself
			array_add(*props, *por.proposal);
			array_add(*senders, fc.sender);
		}
	}

	ng.tree, err = copy_tree(*g.tree);
	if err != .None return err;
	inherit(g, ng);
	ap: Applied;
	ap, err = apply_proposals(g, ng, props, senders, committer);
	if err != .None return err;
	if ap.path_required && !fc.commit.has_path return .Verify;
	if ap.removed_self return .State;

	commit_secret: Secret;
	if fc.commit.has_path {
		commit_secret, err = apply_update_path(g, ng, *fc.commit.path, committer, *ap);
		if err != .None return err;
	}
	tag: Secret;
	tag, err = next_epoch(g, ng, *ap, fc.raw, pm.signature, commit_secret);
	if err != .None return err;
	if !bytes_equal(tag, pm.confirmation_tag) return .Verify;
	// re-home the tree into the new pool (leaves may alias the old group's cache)
	ng.tree, err = copy_tree(*ng.tree);
	if err != .None return err;
	prune_privs(ng);
	return .None;
}

// apply_update_path installs the committer's path and decrypts our path secret.
apply_update_path :: (g: *Group, ng: *Group, path: *Update_Path, committer: u32, ap: *Applied) -> Secret, Error {
	t := *ng.tree;
	if path.leaf.source != .Commit || !verify_leaf_signature(path.leaf, g.ctx.group_id, committer) return ZERO_SECRET, .Verify;
	// leaf key must be fresh
	for l: 0..cast(s64) n_leaves(t) - 1 {
		if l == committer continue;
		o := leaf_at(t, cast(u32) l);
		if o.kind == .Leaf && bytes_equal(o.leaf.encryption_key, path.leaf.encryption_key) return ZERO_SECRET, .Verify;
	}
	tree_blank_path(t, committer);
	fdp := filtered_direct_path(t, committer);
	if fdp.count != path.nodes.count return ZERO_SECRET, .Verify;
	for fdp t.nodes[it] = .{kind = .Parent, parent = .{encryption_key = path.nodes[it_index].encryption_key}};
	if !bytes_equal(set_parent_hashes(t, fdp, committer), path.leaf.parent_hash) return ZERO_SECRET, .Verify;
	leaf_at(t, committer).leaf = path.leaf;

	ctx_bytes := group_context_bytes(provisional_context(g, ng, ap));

	// locate our ciphertext
	me := ng.my_leaf * 2;
	start := -1;
	for fdp if is_ancestor(it, me) { start = it_index; break; }
	if start < 0 return ZERO_SECRET, .State;
	k := 0;
	idx := -1;
	priv: [NSK]u8;
	for nr: resolution(t, sibling_of(child_toward(fdp[start], committer * 2))) {
		if level(nr) == 0 && contains_u32(ap.joiners, nr / 2) continue;
		np := table_find_pointer(*g.privs, nr);
		if np && bytes_equal(node_encryption_key(*t.nodes[nr]), np.pub) {
			idx = k;
			priv = np.priv;
			break;
		}
		k += 1;
	}
	secrets := path.nodes[start].secrets;
	if idx < 0 || idx >= secrets.count return ZERO_SECRET, .State;
	ps, ok := decrypt_with_label(priv, "UpdatePathNode", ctx_bytes, secrets[idx],, temp);
	if !ok || ps.count != NH return ZERO_SECRET, .Crypto;
	cur: Secret;
	memcpy(cur.data, ps.data, NH);
	for i: start..fdp.count-1 {
		kp, kok := derive_key_pair(derive_secret(cur, "node"));
		if !kok return ZERO_SECRET, .Crypto;
		if !bytes_equal(kp.pub, path.nodes[i].encryption_key) return ZERO_SECRET, .Verify;
		table_set(*ng.privs, fdp[i], .{kp.priv, kp.pub});
		cur = derive_secret(cur, "path");
	}
	return cur, .None;
}

// ---------------------------------------------------------------------------
// Commit creation

Commit_Result :: struct {
	commit: []u8; // MLSMessage (PublicMessage)
	welcome: []u8; // Welcome (raw struct, as DAVE sends it); empty without adds
	has_welcome: bool;
	group: *Group; // the next epoch's state, adopt once the commit is accepted
}

// group_commit commits every cached proposal by reference (libdave behaviour:
// inline ratchet tree in the GroupInfo, path only when required). commit and
// welcome are in context.allocator.
group_commit :: (g: *Group, force_path := false) -> Commit_Result, Error {
	res: Commit_Result;
	res.group = group_alloc();
	err := commit(g, res.group, force_path, *res);
	if err != .None {
		group_destroy(res.group);
		return .{}, err;
	}
	return res, .None;
}

commit :: (g: *Group, ng: *Group, force_path: bool, res: *Commit_Result) -> Error {
	out_allocator := context.allocator;
	push_allocator(ng.alloc);
	props: [..]*Proposal;
	senders: [..]Sender;
	refs: [..]Proposal_Or_Ref;
	props.allocator, senders.allocator, refs.allocator = temp, temp, temp;
	for * c: g.proposals {
		array_add(*props, *c.proposal);
		array_add(*senders, c.sender);
		array_add(*refs, .{is_ref = true, ref = c.ref});
	}
	err: Error;
	ng.tree, err = copy_tree(*g.tree);
	if err != .None return err;
	inherit(g, ng);
	ap: Applied;
	ap, err = apply_proposals(g, ng, props, senders, g.my_leaf);
	if err != .None return err;
	if ap.removed_self return .State;
	t := *ng.tree;
	commit := Commit.{proposals = refs};
	commit_secret: Secret;
	path_secrets: [..]Secret;
	path_secrets.allocator = temp;
	fdp: []u32;
	if ap.path_required || force_path {
		commit.has_path = true;
		leaf_secret: Secret;
		crypto.random_bytes(leaf_secret);
		leaf_kp, ok := derive_key_pair(derive_secret(leaf_secret, "node"));
		if !ok return .Crypto;
		tree_blank_path(t, g.my_leaf);
		fdp = filtered_direct_path(t, g.my_leaf);
		cur := derive_secret(leaf_secret, "path");
		nodes := NewArray(fdp.count, Update_Path_Node,, temp);
		for x, i: fdp {
			array_add(*path_secrets, cur);
			kp, ok2 := derive_key_pair(derive_secret(cur, "node"));
			if !ok2 return .Crypto;
			t.nodes[x] = .{kind = .Parent, parent = .{encryption_key = clone_bytes(kp.pub)}};
			table_set(*ng.privs, x, .{kp.priv, kp.pub});
			nodes[i].encryption_key = t.nodes[x].parent.encryption_key;
			cur = derive_secret(cur, "path");
		}
		commit_secret = cur;
		mx := g.my_leaf * 2;
		nl := leaf_at(*g.tree, g.my_leaf).leaf;
		nl.encryption_key = clone_bytes(leaf_kp.pub);
		nl.source = .Commit;
		nl.parent_hash = set_parent_hashes(t, fdp, g.my_leaf);
		nl.not_before = 0;
		nl.not_after = 0;
		nl.signature, ok = sign_with_label(g.sig_priv, "LeafNodeTBS", leaf_node_tbs(nl, g.ctx.group_id, g.my_leaf));
		if !ok return .Crypto;
		leaf_at(t, g.my_leaf).leaf = nl;
		table_set(*ng.privs, mx, .{leaf_kp.priv, leaf_kp.pub});
		ctx_bytes := group_context_bytes(provisional_context(g, ng, *ap));
		for x, i: fdp {
			res_nodes := resolution(t, sibling_of(child_toward(x, mx)));
			cts: [..]Hpke_Ciphertext;
			cts.allocator = temp;
			for nr: res_nodes {
				if level(nr) == 0 && contains_u32(ap.joiners, nr / 2) continue;
				ct, eok := encrypt_with_label(node_encryption_key(*t.nodes[nr]), "UpdatePathNode", ctx_bytes, path_secrets[i],, temp);
				if !eok return .Crypto;
				array_add(*cts, ct);
			}
			nodes[i].secrets = cts;
		}
		commit.path = .{leaf = nl, nodes = nodes};
	}

	fc := Framed_Content.{group_id = g.ctx.group_id, epoch = g.ctx.epoch, sender = .{.Member, g.my_leaf}, content_type = .Commit, commit = commit};
	content_raw := framed_content_bytes(fc);
	tbs := framed_content_tbs(content_raw, fc.sender, group_context_bytes(g.ctx));
	signature, sok := sign_with_label(g.sig_priv, "FramedContentTBS", tbs,, temp);
	if !sok return .Crypto;
	tag: Secret;
	tag, err = next_epoch(g, ng, *ap, content_raw, signature, commit_secret);
	if err != .None return err;
	mtag := membership_tag(g.ks.membership_key, tbs, signature, tag, true);

	w := writer_make(out_allocator);
	w_u16(*w, PROTOCOL_VERSION);
	w_u16(*w, cast(u16) Wire_Format.Public_Message);
	w_raw(*w, content_raw);
	w_vec(*w, signature);
	w_vec(*w, tag);
	w_vec(*w, mtag);
	res.commit = w.buf;

	if ap.joiners.count {
		res.welcome, err = build_welcome(g, ng, *ap, fdp, path_secrets, tag,, out_allocator);
		if err != .None return err;
		res.has_welcome = true;
	}
	ng.tree, err = copy_tree(*ng.tree);
	if err != .None return err;
	prune_privs(ng);
	return .None;
}

// build_welcome encodes the Welcome in context.allocator.
build_welcome :: (g: *Group, ng: *Group, ap: *Applied, fdp: []u32, path_secrets: []Secret, conf_tag: []u8) -> []u8, Error {
	ext_kp, ok := derive_key_pair(ng.ks.external);
	if !ok return .[], .Crypto;
	ep := writer_make();
	w_vec(*ep, ext_kp.pub);
	exts := Extension.[.{EXT_EXTERNAL_PUB, ep.buf}, .{EXT_RATCHET_TREE, ratchet_tree_bytes(*ng.tree)}];
	gi := Group_Info.{ctx = ng.ctx, extensions = exts, confirmation_tag = conf_tag, signer = g.my_leaf};
	tbs := group_info_tbs(gi);
	sig, sok := sign_with_label(g.sig_priv, "GroupInfoTBS", tbs,, temp);
	if !sok return .[], .Crypto;
	giw := writer_make();
	w_raw(*giw, tbs);
	w_vec(*giw, sig);
	key, nonce := welcome_key_nonce(ng.ks.welcome);
	egi := aead_seal(key, nonce, .[], giw.buf,, temp);

	secrets := NewArray(ap.joiners.count, Encrypted_Group_Secrets,, temp);
	for j, ji: ap.joiners {
		kp := ap.joiner_kps[ji];
		gs := writer_make();
		w_vec(*gs, ng.ks.joiner);
		ps_idx := -1;
		for fdp if is_ancestor(it, j * 2) { ps_idx = it_index; break; }
		w_optional(*gs, ps_idx >= 0);
		if ps_idx >= 0 w_vec(*gs, path_secrets[ps_idx]);
		pp := w_begin(*gs);
		for ap.psks w_psk_id(*gs, it);
		w_end(*gs, pp);
		ct, eok := encrypt_with_label(kp.init_key, "Welcome", egi, gs.buf,, temp);
		if !eok return .[], .Crypto;
		ref := key_package_ref(kp.raw);
		secrets[ji] = .{new_member = array_copy(ref,, temp), secrets = ct};
	}
	w := writer_make(context.allocator);
	w_welcome(*w, .{cipher_suite = CIPHER_SUITE, secrets = secrets, encrypted_group_info = egi});
	return w.buf, .None;
}

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
	ng := group_alloc();
	err := join(ng, welcome_bytes, p);
	if err != .None {
		group_destroy(ng);
		return null, err;
	}
	return ng, .None;
}

join :: (ng: *Group, welcome_bytes: []u8, p: Join_Params) -> Error {
	push_allocator(ng.alloc);
	for p.ext_psks group_add_external_psk(ng, it.id, it.secret);
	r := reader_make(clone_bytes(welcome_bytes));
	wel := r_welcome(*r);
	if !r_done(*r) return .Decode;
	if wel.cipher_suite != CIPHER_SUITE return .Unsupported;
	my_ref := key_package_ref(p.key_package.raw);
	egs: *Encrypted_Group_Secrets;
	for * wel.secrets if bytes_equal(it.new_member, my_ref) egs = it;
	if !egs return .State;
	gs_bytes, ok := decrypt_with_label(p.secrets.init_priv, "Welcome", wel.encrypted_group_info, egs.secrets);
	if !ok return .Crypto;
	gr := reader_make(gs_bytes);
	gs := r_group_secrets(*gr);
	if !r_done(*gr) || gs.joiner_secret.count != NH return .Decode;

	// psk secret: computed against an empty group (external PSKs only)
	psk_secret, err := compute_psk_secret(ng, gs.psks);
	if err != .None return err;
	memcpy(ng.ks.joiner.data, gs.joiner_secret.data, NH);
	m := kdf_extract(ng.ks.joiner, psk_secret);  // psk_secret is zero without PSKs
	ng.ks.welcome = derive_secret(m, "welcome");
	key, nonce := welcome_key_nonce(ng.ks.welcome);
	gi_bytes, ok2 := aead_open(key, nonce, .[], wel.encrypted_group_info);
	if !ok2 return .Crypto;
	ir := reader_make(gi_bytes);
	gi := r_group_info(*ir);
	if !r_done(*ir) return .Decode;
	if gi.ctx.cipher_suite != CIPHER_SUITE || gi.ctx.version != PROTOCOL_VERSION return .Unsupported;

	tree_bytes := p.ratchet_tree;
	e, has := find_extension(gi.extensions, EXT_RATCHET_TREE);
	if has tree_bytes = e.data;
	if !tree_bytes.data return .State;
	ng.tree, err = parse_ratchet_tree(clone_bytes(tree_bytes));
	if err != .None return err;
	t := *ng.tree;

	signer := member_leaf(ng, gi.signer);
	if !signer || !verify_with_label(signer.signature_key, "GroupInfoTBS", group_info_tbs(gi), gi.signature) return .Verify;
	err = tree_validate(t, gi.ctx.group_id, gi.ctx.tree_hash);
	if err != .None return err;

	// find our leaf
	found := false;
	for l: 0..cast(s64) n_leaves(t) - 1 {
		n := leaf_at(t, cast(u32) l);
		if n.kind == .Leaf && bytes_equal(n.leaf.encryption_key, p.key_package.leaf.encryption_key) && bytes_equal(n.leaf.signature_key, p.key_package.leaf.signature_key) {
			ng.my_leaf = cast(u32) l;
			found = true;
			break;
		}
	}
	if !found return .State;
	ng.sig_priv = p.sig_priv;
	lp := public_from_private(p.secrets.leaf_priv);
	table_set(*ng.privs, ng.my_leaf * 2, .{p.secrets.leaf_priv, lp});

	if gs.has_path_secret {
		if gs.path_secret.count != NH return .Decode;
		lca := common_ancestor(ng.my_leaf * 2, gi.signer * 2);
		cur: Secret;
		memcpy(cur.data, gs.path_secret.data, NH);
		started := false;
		for x: filtered_direct_path(t, gi.signer) {
			if x == lca started = true;
			if !started continue;
			kp, kok := derive_key_pair(derive_secret(cur, "node"));
			if !kok return .Crypto;
			if !bytes_equal(kp.pub, node_encryption_key(*t.nodes[x])) return .Verify;
			table_set(*ng.privs, x, .{kp.priv, kp.pub});
			cur = derive_secret(cur, "path");
		}
		if !started return .Verify;
	}

	ng.ctx = gi.ctx;
	expand_with_label(m, "epoch", group_context_bytes(ng.ctx), ng.ks.epoch);
	key_schedule_from_epoch(*ng.ks);
	tag := mac(ng.ks.confirmation_key, ng.ctx.confirmed_transcript_hash);
	if !bytes_equal(tag, gi.confirmation_tag) return .Verify;
	ng.interim = interim_hash(ng.ctx.confirmed_transcript_hash, gi.confirmation_tag);
	return .None;
}

// ---------------------------------------------------------------------------
// External sender messages (used by the voice gateway; here for tests/fakes)

// external_proposal encodes the PublicMessage in context.allocator.
external_proposal :: (group_id: []u8, ep: u64, sender_index: u32, prop: Proposal, sig_priv: []u8) -> []u8, bool {
	fc := Framed_Content.{group_id = group_id, epoch = ep, sender = .{.External, sender_index}, content_type = .Proposal, proposal = prop};
	raw := framed_content_bytes(fc);
	sig, ok := sign_with_label(sig_priv, "FramedContentTBS", framed_content_tbs(raw, fc.sender, .[]),, temp);
	if !ok return .[], false;
	w := writer_make(context.allocator);
	w_u16(*w, PROTOCOL_VERSION);
	w_u16(*w, cast(u16) Wire_Format.Public_Message);
	w_raw(*w, raw);
	w_vec(*w, sig);
	return w.buf, true;
}

// find_member: leaf index of the member whose basic credential identity equals identity.
find_member :: (g: *Group, identity: []u8) -> u32, bool {
	for l: 0..cast(s64) n_leaves(*g.tree) - 1 {
		n := leaf_at(*g.tree, cast(u32) l);
		if n.kind == .Leaf && bytes_equal(n.leaf.credential.data, identity) return cast(u32) l, true;
	}
	return 0, false;
}

#scope_file
default_versions := u16.[PROTOCOL_VERSION];
default_suites := u16.[CIPHER_SUITE];
default_credentials := u16.[CRED_BASIC];
