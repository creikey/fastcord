package mls

import "core:crypto"
import "core:mem"
import "core:mem/virtual"

// Group: one epoch of MLS group state. Every state transition (commit,
// welcome) produces a NEW Group with its own arena, leaving the old one
// intact (DAVE keeps the previous epoch around until a transition executes).

Node_Priv :: struct {
	priv: [NSK]byte,
	pub:  [NPK]byte,
}

Epoch_Secrets :: struct {
	joiner:              Secret,
	welcome:             Secret,
	epoch:               Secret,
	sender_data:         Secret,
	encryption:          Secret,
	exporter:            Secret,
	external:            Secret,
	confirmation_key:    Secret,
	membership_key:      Secret,
	resumption_psk:      Secret,
	epoch_authenticator: Secret,
	init:                Secret,
}

Cached_Proposal :: struct {
	ref:      Secret,
	proposal: Proposal,
	sender:   Sender,
}

Psk_Entry :: struct {
	id:     []byte,
	secret: []byte,
}

Resumption_Entry :: struct {
	epoch:  u64,
	secret: Secret,
}

// Identity is the long-lived signing identity of the local member.
Identity :: struct {
	sig_priv:   [NSK]byte,
	sig_pub:    [NPK]byte,
	credential: Credential,
}

Group :: struct {
	arena:       virtual.Arena,
	alloc:       mem.Allocator,
	ctx:         Group_Context,
	tree:        Tree,
	my_leaf:     u32,
	sig_priv:    [NSK]byte,
	privs:       map[u32]Node_Priv,
	interim:     Secret,
	ks:          Epoch_Secrets,
	proposals:   [dynamic]Cached_Proposal,
	ext_psks:    [dynamic]Psk_Entry,
	resumption:  [dynamic]Resumption_Entry, // previous epochs (most recent last)
}

group_alloc :: proc() -> ^Group {
	g := new(Group)
	if virtual.arena_init_growing(&g.arena) != nil {
		free(g)
		return nil
	}
	g.alloc = virtual.arena_allocator(&g.arena)
	g.privs = make(map[u32]Node_Priv, g.alloc)
	g.proposals = make([dynamic]Cached_Proposal, 0, 4, g.alloc)
	g.ext_psks = make([dynamic]Psk_Entry, 0, 1, g.alloc)
	g.resumption = make([dynamic]Resumption_Entry, 0, 4, g.alloc)
	return g
}

group_destroy :: proc(g: ^Group) {
	if g == nil do return
	crypto.zero_explicit(&g.ks, size_of(g.ks))
	crypto.zero_explicit(&g.sig_priv, size_of(g.sig_priv))
	virtual.arena_destroy(&g.arena)
	free(g)
}

group_add_external_psk :: proc(g: ^Group, id, secret: []byte) {
	append(&g.ext_psks, Psk_Entry{clone_bytes(id, g.alloc), clone_bytes(secret, g.alloc)})
}

epoch :: proc(g: ^Group) -> u64 {return g.ctx.epoch}
group_id :: proc(g: ^Group) -> []byte {return g.ctx.group_id}
epoch_authenticator :: proc(g: ^Group) -> Secret {return g.ks.epoch_authenticator}

// exporter: MLS-Exporter(label, context, length) (RFC 9420 8.5).
exporter :: proc(g: ^Group, label: string, ctx: []byte, dst: []byte) {
	s := derive_secret(g.ks.exporter[:], label)
	h := hash_bytes(ctx)
	expand_with_label(s[:], "exported", h[:], dst)
}

member_leaf :: proc(g: ^Group, leaf: u32) -> (^Leaf_Node, bool) {
	n := leaf_at(&g.tree, leaf)
	if n == nil || n.kind != .Leaf do return nil, false
	return &n.leaf, true
}

// ---------------------------------------------------------------------------
// Key schedule

key_schedule_from_joiner :: proc(ks: ^Epoch_Secrets, psk_secret, ctx_bytes: []byte) {
	zero: Secret
	psk := psk_secret if len(psk_secret) > 0 else zero[:]
	m := kdf_extract(ks.joiner[:], psk)
	ks.welcome = derive_secret(m[:], "welcome")
	expand_with_label(m[:], "epoch", ctx_bytes, ks.epoch[:])
	key_schedule_from_epoch(ks)
}

key_schedule_from_epoch :: proc(ks: ^Epoch_Secrets) {
	e := ks.epoch[:]
	ks.sender_data = derive_secret(e, "sender data")
	ks.encryption = derive_secret(e, "encryption")
	ks.exporter = derive_secret(e, "exporter")
	ks.external = derive_secret(e, "external")
	ks.confirmation_key = derive_secret(e, "confirm")
	ks.membership_key = derive_secret(e, "membership")
	ks.resumption_psk = derive_secret(e, "resumption")
	ks.epoch_authenticator = derive_secret(e, "authentication")
	ks.init = derive_secret(e, "init")
}

key_schedule :: proc(init_prev, commit_secret, psk_secret, ctx_bytes: []byte) -> (ks: Epoch_Secrets) {
	x := kdf_extract(init_prev, commit_secret)
	expand_with_label(x[:], "joiner", ctx_bytes, ks.joiner[:])
	key_schedule_from_joiner(&ks, psk_secret, ctx_bytes)
	return
}

welcome_key_nonce :: proc(welcome_secret: []byte) -> (key: [NK]byte, nonce: [NN]byte) {
	expand_with_label(welcome_secret, "key", nil, key[:])
	expand_with_label(welcome_secret, "nonce", nil, nonce[:])
	return
}

// psk_secret (RFC 9420 8.4). lookup returns the PSK value for an id.
compute_psk_secret :: proc(g: ^Group, psks: []Psk_Id) -> (out: Secret, err: Error) {
	if len(psks) == 0 do return
	zero: Secret
	acc := zero
	for p, i in psks {
		value: []byte
		switch p.type {
		case 1:
			for e in g.ext_psks do if bytes_equal(e.id, p.id) do value = e.secret
		case 2:
			if p.usage != 1 do return out, .Unsupported // only "application" resumption
			if !bytes_equal(p.group_id, g.ctx.group_id) do return out, .Unsupported
			if p.epoch == g.ctx.epoch {
				value = g.ks.resumption_psk[:]
			} else {
				for &e in g.resumption do if e.epoch == p.epoch do value = e.secret[:]
			}
		}
		if value == nil do return out, .State
		extracted := kdf_extract(nil, value)
		w := writer_make()
		w_psk_id(&w, p)
		w_u16(&w, u16(i))
		w_u16(&w, u16(len(psks)))
		input: Secret
		expand_with_label(extracted[:], "derived psk", w.buf[:], input[:])
		acc = kdf_extract(input[:], acc[:])
	}
	return acc, .None
}

// ---------------------------------------------------------------------------
// Transcript hashes

confirmed_hash :: proc(interim: []byte, wire_format: Wire_Format, content_raw, signature: []byte) -> Secret {
	w := writer_make()
	w_raw(&w, interim)
	w_u16(&w, u16(wire_format))
	w_raw(&w, content_raw)
	w_vec(&w, signature)
	return hash_bytes(w.buf[:])
}

interim_hash :: proc(confirmed, confirmation_tag: []byte) -> Secret {
	w := writer_make()
	w_raw(&w, confirmed)
	w_vec(&w, confirmation_tag)
	return hash_bytes(w.buf[:])
}

// ---------------------------------------------------------------------------
// Framing helpers

framed_content_tbs :: proc(content_raw: []byte, sender: Sender, ctx_bytes: []byte) -> []byte {
	w := writer_make()
	w_u16(&w, PROTOCOL_VERSION)
	w_u16(&w, u16(Wire_Format.Public_Message))
	w_raw(&w, content_raw)
	if sender.type == .Member || sender.type == .New_Member_Commit do w_raw(&w, ctx_bytes)
	return w.buf[:]
}

auth_data_bytes :: proc(signature, confirmation_tag: []byte, is_commit: bool) -> []byte {
	w := writer_make()
	w_vec(&w, signature)
	if is_commit do w_vec(&w, confirmation_tag)
	return w.buf[:]
}

// authenticated_content: wire_format || FramedContent || FramedContentAuthData
authenticated_content :: proc(content_raw, signature, confirmation_tag: []byte, is_commit: bool) -> []byte {
	w := writer_make()
	w_u16(&w, u16(Wire_Format.Public_Message))
	w_raw(&w, content_raw)
	w_raw(&w, auth_data_bytes(signature, confirmation_tag, is_commit))
	return w.buf[:]
}

proposal_ref :: proc(content_raw, signature: []byte) -> Secret {
	return ref_hash("MLS 1.0 Proposal Reference", authenticated_content(content_raw, signature, nil, false))
}

key_package_ref :: proc(kp_raw: []byte) -> Secret {
	return ref_hash("MLS 1.0 KeyPackage Reference", kp_raw)
}

external_senders :: proc(g: ^Group, a := context.temp_allocator) -> []External_Sender {
	e, ok := find_extension(g.ctx.extensions, EXT_EXTERNAL_SENDERS)
	if !ok do return nil
	r := reader_make(e.data)
	sub := r_sub(&r)
	out := make([dynamic]External_Sender, 0, 1, a)
	for r_ok(&sub) && r_left(&sub) > 0 do append(&out, r_external_sender(&sub))
	return out[:]
}

external_senders_extension :: proc(senders: []External_Sender, a := context.temp_allocator) -> Extension {
	w := writer_make(a)
	p := w_begin(&w)
	for s in senders do w_external_sender(&w, s)
	w_end(&w, p)
	return Extension{EXT_EXTERNAL_SENDERS, w.buf[:]}
}

// verify_public_message: epoch / group checks, signature and membership tag.
verify_public_message :: proc(g: ^Group, pm: ^Public_Message) -> Error {
	fc := &pm.content
	if !bytes_equal(fc.group_id, g.ctx.group_id) do return .State
	if fc.epoch != g.ctx.epoch do return .State
	ctx_bytes := group_context_bytes(g.ctx)
	sig_key: []byte
	#partial switch fc.sender.type {
	case .Member:
		ln, ok := member_leaf(g, fc.sender.index)
		if !ok do return .State
		sig_key = ln.signature_key
	case .External:
		es := external_senders(g)
		if int(fc.sender.index) >= len(es) do return .State
		sig_key = es[fc.sender.index].signature_key
	case:
		return .Unsupported
	}
	tbs := framed_content_tbs(fc.raw, fc.sender, ctx_bytes)
	if !verify_with_label(sig_key, "FramedContentTBS", tbs, pm.signature) do return .Verify
	if fc.sender.type == .Member {
		w := writer_make()
		w_raw(&w, tbs)
		w_raw(&w, auth_data_bytes(pm.signature, pm.confirmation_tag, fc.content_type == .Commit))
		tag := mac(g.ks.membership_key[:], w.buf[:])
		if !bytes_equal(tag[:], pm.membership_tag) do return .Verify
	}
	return .None
}

validate_key_package :: proc(kp: ^Key_Package) -> Error {
	if kp.version != PROTOCOL_VERSION || kp.cipher_suite != CIPHER_SUITE do return .Unsupported
	if kp.leaf.source != .Key_Package do return .Verify
	if bytes_equal(kp.init_key, kp.leaf.encryption_key) do return .Verify
	if !verify_with_label(kp.leaf.signature_key, "KeyPackageTBS", key_package_tbs(kp^), kp.signature) do return .Verify
	if !verify_leaf_signature(kp.leaf, nil, 0) do return .Verify
	return .None
}

// group_cache_proposal verifies and caches a proposal (PublicMessage bytes).
// Returns the cached proposal ref.
group_cache_proposal :: proc(g: ^Group, msg_bytes: []byte) -> (ref: Secret, prop: ^Cached_Proposal, err: Error) {
	b := clone_bytes(msg_bytes, g.alloc)
	m := parse_mls_message(b, g.alloc) or_return
	if m.wire_format != .Public_Message do return ref, nil, .Unsupported
	pm := &m.public
	if pm.content.content_type != .Proposal do return ref, nil, .State
	verify_public_message(g, pm) or_return
	ref = proposal_ref(pm.content.raw, pm.signature)
	for &c in g.proposals do if c.ref == ref do return ref, &c, .None
	if pm.content.proposal.type == .Add {
		validate_key_package(&pm.content.proposal.add) or_return
	}
	append(&g.proposals, Cached_Proposal{ref = ref, proposal = pm.content.proposal, sender = pm.content.sender})
	return ref, &g.proposals[len(g.proposals) - 1], .None
}

group_revoke_proposal :: proc(g: ^Group, ref: []byte) -> bool {
	for &c, i in g.proposals {
		if bytes_equal(c.ref[:], ref) {
			ordered_remove(&g.proposals, i)
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------------------
// Rebase: deep copy the tree / context into another group's arena by
// serializing and re-parsing.

@(private)
copy_tree :: proc(t: ^Tree, a: mem.Allocator) -> (out: Tree, err: Error) {
	if len(t.nodes) == 0 do return out, .State
	b := clone_bytes(ratchet_tree_bytes(t), a)
	out, err = parse_ratchet_tree(b, a)
	if err != .None do return
	// preserve full width (parse trims to the minimal full tree)
	for len(out.nodes) < len(t.nodes) do append(&out.nodes, Node{})
	return
}

@(private)
copy_context :: proc(gc: Group_Context, a: mem.Allocator) -> (out: Group_Context, err: Error) {
	b := clone_bytes(group_context_bytes(gc), a)
	r := reader_make(b)
	out = r_group_context(&r, a)
	if !r_done(&r) do return out, .Decode
	return out, .None
}

@(private)
inherit :: proc(old, ng: ^Group) {
	ng.my_leaf = old.my_leaf
	ng.sig_priv = old.sig_priv
	for e in old.ext_psks do append(&ng.ext_psks, Psk_Entry{clone_bytes(e.id, ng.alloc), clone_bytes(e.secret, ng.alloc)})
	for e in old.resumption do append(&ng.resumption, e)
	append(&ng.resumption, Resumption_Entry{old.ctx.epoch, old.ks.resumption_psk})
	if len(ng.resumption) > 16 do ordered_remove(&ng.resumption, 0)
}

// drop private keys whose node changed
@(private)
prune_privs :: proc(g: ^Group) {
	stale := make([dynamic]u32, 0, 4, context.temp_allocator)
	for idx, np in g.privs {
		if int(idx) >= len(g.tree.nodes) {
			append(&stale, idx)
			continue
		}
		k := node_encryption_key(&g.tree.nodes[idx])
		pub := np.pub
		if !bytes_equal(k, pub[:]) do append(&stale, idx)
	}
	for idx in stale do delete_key(&g.privs, idx)
}

// ---------------------------------------------------------------------------
// Creation & key packages

Key_Package_Secrets :: struct {
	init_priv: [NSK]byte,
	leaf_priv: [NSK]byte,
}

default_capabilities :: proc() -> Capabilities {
	@(static) versions := [1]u16{PROTOCOL_VERSION}
	@(static) suites := [1]u16{CIPHER_SUITE}
	@(static) creds := [1]u16{CRED_BASIC}
	return Capabilities{versions = versions[:], cipher_suites = suites[:], credentials = creds[:]}
}

// key_package_create builds a signed KeyPackage the way libdave does:
// basic credential, lifetime [0, 2^64-1], no extensions. Returns the
// KeyPackage (serialized as an MLSMessage) and its private keys.
key_package_create :: proc(id: ^Identity, allocator := context.allocator) -> (msg: []byte, kp: Key_Package, secrets: Key_Package_Secrets) {
	init := generate_key_pair()
	leaf := generate_key_pair()
	secrets.init_priv = init.priv
	secrets.leaf_priv = leaf.priv
	kp.version = PROTOCOL_VERSION
	kp.cipher_suite = CIPHER_SUITE
	kp.init_key = clone_bytes(init.pub[:], allocator)
	kp.leaf = Leaf_Node {
		encryption_key = clone_bytes(leaf.pub[:], allocator),
		signature_key  = clone_bytes(id.sig_pub[:], allocator),
		credential     = Credential{id.credential.type, clone_bytes(id.credential.data, allocator)},
		capabilities   = default_capabilities(),
		source         = .Key_Package,
		not_before     = 0,
		not_after      = max(u64),
	}
	sig, ok := sign_with_label(id.sig_priv[:], "LeafNodeTBS", leaf_node_tbs(kp.leaf, nil, 0), allocator)
	assert(ok)
	kp.leaf.signature = sig
	sig2, ok2 := sign_with_label(id.sig_priv[:], "KeyPackageTBS", key_package_tbs(kp), allocator)
	assert(ok2)
	kp.signature = sig2
	w := writer_make(allocator)
	w_u16(&w, PROTOCOL_VERSION)
	w_u16(&w, u16(Wire_Format.Key_Package))
	w_key_package(&w, kp)
	msg = w.buf[:]
	kp.raw = msg[4:]
	return
}

// group_create: a one-member group at epoch 0 using the leaf from our key package.
group_create :: proc(gid: []byte, id: ^Identity, kp: ^Key_Package, secrets: ^Key_Package_Secrets, extensions: []Extension) -> (g: ^Group, err: Error) {
	g = group_alloc()
	a := g.alloc
	g.sig_priv = id.sig_priv
	g.tree.nodes = make([dynamic]Node, 0, 1, a)
	b := clone_bytes(kp.raw, a)
	r := reader_make(b)
	kp2 := r_key_package(&r, a)
	if !r_done(&r) {
		group_destroy(g)
		return nil, .Decode
	}
	append(&g.tree.nodes, Node{kind = .Leaf, leaf = kp2.leaf})
	g.my_leaf = 0
	lp, _ := public_from_private(secrets.leaf_priv[:])
	g.privs[0] = Node_Priv{secrets.leaf_priv, lp}
	th := root_tree_hash(&g.tree)
	gc := Group_Context {
		version      = PROTOCOL_VERSION,
		cipher_suite = CIPHER_SUITE,
		group_id     = gid,
		epoch        = 0,
		tree_hash    = th[:],
		extensions   = extensions,
	}
	g.ctx, err = copy_context(gc, a)
	if err != .None {
		group_destroy(g)
		return nil, err
	}
	crypto.rand_bytes(g.ks.epoch[:])
	key_schedule_from_epoch(&g.ks)
	tag := mac(g.ks.confirmation_key[:], nil)
	g.interim = interim_hash(nil, tag[:])
	return g, .None
}

// ---------------------------------------------------------------------------
// Proposal application (shared by commit creation and processing)

@(private)
Applied :: struct {
	joiners:       [dynamic]u32, // new leaf indices
	joiner_kps:    [dynamic]^Key_Package,
	psks:          [dynamic]Psk_Id,
	new_exts:      []Extension,
	has_new_exts:  bool,
	path_required: bool,
	removed_self:  bool,
}

@(private)
apply_proposals :: proc(g, ng: ^Group, props: []^Proposal, senders: []Sender, committer: u32) -> (ap: Applied, err: Error) {
	ap.joiners = make([dynamic]u32, 0, 2, context.temp_allocator)
	ap.joiner_kps = make([dynamic]^Key_Package, 0, 2, context.temp_allocator)
	ap.psks = make([dynamic]Psk_Id, 0, 1, context.temp_allocator)
	if len(props) == 0 do ap.path_required = true
	t := &ng.tree
	// 1. GroupContextExtensions
	for p in props {
		if p.type == .Group_Context_Extensions {
			if ap.has_new_exts do return ap, .Verify
			ap.new_exts = p.extensions
			ap.has_new_exts = true
			ap.path_required = true
		}
	}
	// 2. Updates
	for p, i in props {
		if p.type != .Update do continue
		s := senders[i]
		if s.type != .Member || s.index == committer do return ap, .Verify
		if p.update.source != .Update do return ap, .Verify
		if !verify_leaf_signature(p.update, g.ctx.group_id, s.index) do return ap, .Verify
		n := leaf_at(t, s.index)
		if n == nil || n.kind != .Leaf do return ap, .Verify
		n.leaf = p.update
		tree_blank_path(t, s.index)
		ap.path_required = true
	}
	// 3. Removes
	for p in props {
		if p.type != .Remove do continue
		n := leaf_at(t, p.remove)
		if n == nil || n.kind != .Leaf do return ap, .Verify
		if p.remove == committer do return ap, .Verify
		if p.remove == g.my_leaf do ap.removed_self = true
		n^ = Node{}
		tree_blank_path(t, p.remove)
		ap.path_required = true
	}
	tree_truncate(t)
	// 4. Adds
	for p in props {
		if p.type != .Add do continue
		validate_key_package(&p.add) or_return
		for l in 0 ..< n_leaves(t) {
			o := leaf_at(t, l)
			if o.kind == .Leaf && (bytes_equal(o.leaf.signature_key, p.add.leaf.signature_key) || bytes_equal(o.leaf.encryption_key, p.add.leaf.encryption_key)) do return ap, .Verify
		}
		idx := tree_add_leaf(t, p.add.leaf, ng.alloc)
		append(&ap.joiners, idx)
		append(&ap.joiner_kps, &p.add)
	}
	// 5. PSKs
	for p in props {
		if p.type == .Psk do append(&ap.psks, p.psk)
		if p.type == .Reinit || p.type == .External_Init do return ap, .Unsupported
	}
	return ap, .None
}

@(private)
provisional_context :: proc(g: ^Group, ng: ^Group, ap: ^Applied) -> (gc: Group_Context, bytes: []byte) {
	th := root_tree_hash(&ng.tree)
	gc = g.ctx
	gc.epoch = g.ctx.epoch + 1
	gc.tree_hash = clone_bytes(th[:], context.temp_allocator)
	if ap.has_new_exts do gc.extensions = ap.new_exts
	return gc, group_context_bytes(gc)
}

// ---------------------------------------------------------------------------
// Commit processing (another member's commit)

group_process_commit :: proc(g: ^Group, msg_bytes: []byte) -> (res: ^Group, err: Error) {
	ng := group_alloc()
	defer if err != .None do group_destroy(ng)
	b := clone_bytes(msg_bytes, ng.alloc)
	m := parse_mls_message(b, ng.alloc) or_return
	if m.wire_format != .Public_Message do return nil, .Unsupported
	pm := &m.public
	fc := &pm.content
	if fc.content_type != .Commit do return nil, .State
	if fc.sender.type != .Member do return nil, .Unsupported
	committer := fc.sender.index
	if committer == g.my_leaf do return nil, .State // own commits are adopted, not processed
	verify_public_message(g, pm) or_return

	// resolve proposals
	props := make([dynamic]^Proposal, 0, len(fc.commit.proposals), context.temp_allocator)
	senders := make([dynamic]Sender, 0, len(fc.commit.proposals), context.temp_allocator)
	for &por in fc.commit.proposals {
		if por.is_ref {
			found := false
			for &c in g.proposals {
				if bytes_equal(c.ref[:], por.ref) {
					append(&props, &c.proposal)
					append(&senders, c.sender)
					found = true
					break
				}
			}
			if !found do return nil, .State
		} else {
			if por.proposal.type == .Update do return nil, .Verify // committer cannot inline-update itself
			append(&props, &por.proposal)
			append(&senders, fc.sender)
		}
	}

	ng.tree = copy_tree(&g.tree, ng.alloc) or_return
	inherit(g, ng)
	for idx, np in g.privs do ng.privs[idx] = np
	ap := apply_proposals(g, ng, props[:], senders[:], committer) or_return
	if ap.path_required && !fc.commit.has_path do return nil, .Verify
	if ap.removed_self do return nil, .State

	zero: Secret
	commit_secret := zero
	if fc.commit.has_path {
		commit_secret = apply_update_path(g, ng, &fc.commit.path, committer, &ap) or_return
	}

	// new context and key schedule
	gc, _ := provisional_context(g, ng, &ap)
	confirmed := confirmed_hash(g.interim[:], .Public_Message, fc.raw, pm.signature)
	gc.confirmed_transcript_hash = confirmed[:]
	ng.ctx = copy_context(gc, ng.alloc) or_return
	ctx_bytes := group_context_bytes(ng.ctx)
	psk_secret := compute_psk_secret(g, ap.psks[:]) or_return
	psk_slice: []byte = psk_secret[:] if len(ap.psks) > 0 else nil
	ng.ks = key_schedule(g.ks.init[:], commit_secret[:], psk_slice, ctx_bytes)
	tag := mac(ng.ks.confirmation_key[:], confirmed[:])
	if !bytes_equal(tag[:], pm.confirmation_tag) do return nil, .Verify
	ng.interim = interim_hash(confirmed[:], tag[:])
	// re-home tree into the new arena (leaves may alias the old group's cache)
	t2 := copy_tree(&ng.tree, ng.alloc) or_return
	ng.tree = t2
	prune_privs(ng)
	return ng, .None
}

// apply_update_path installs the committer's path and decrypts our path secret.
@(private)
apply_update_path :: proc(g, ng: ^Group, path: ^Update_Path, committer: u32, ap: ^Applied) -> (commit_secret: Secret, err: Error) {
	t := &ng.tree
	if path.leaf.source != .Commit do return commit_secret, .Verify
	if !verify_leaf_signature(path.leaf, g.ctx.group_id, committer) do return commit_secret, .Verify
	// leaf key must be fresh
	for l in 0 ..< n_leaves(t) {
		if l == committer do continue
		o := leaf_at(t, l)
		if o.kind == .Leaf && bytes_equal(o.leaf.encryption_key, path.leaf.encryption_key) do return commit_secret, .Verify
	}
	tree_blank_path(t, committer)
	fdp := filtered_direct_path(t, committer)
	if len(fdp) != len(path.nodes) do return commit_secret, .Verify
	for x, i in fdp {
		t.nodes[x] = Node{kind = .Parent, parent = Parent_Node{encryption_key = path.nodes[i].encryption_key}}
	}
	// parent hashes, top-down
	ph: []byte = nil
	cx := committer * 2
	for i := len(fdp) - 1; i >= 0; i -= 1 {
		p := fdp[i]
		t.nodes[p].parent.parent_hash = ph
		sib := sibling_of(child_toward(p, cx)) // copath child
		sh := tree_hash(t, sib)
		h := parent_hash_of(t.nodes[p].parent.encryption_key, ph, sh[:])
		ph = clone_bytes(h[:], ng.alloc)
	}
	if !bytes_equal(ph, path.leaf.parent_hash) do return commit_secret, .Verify
	leaf_at(t, committer).leaf = path.leaf

	_, ctx_bytes := provisional_context(g, ng, ap)

	// locate our ciphertext
	me := ng.my_leaf * 2
	start := -1
	for x, i in fdp {
		if is_ancestor(x, me) {
			start = i
			break
		}
	}
	if start < 0 do return commit_secret, .State
	cp := sibling_of(child_toward(fdp[start], cx))
	res := resolution(t, cp)
	k := 0
	idx := -1
	priv: [NSK]byte
	for nr in res {
		if level(nr) == 0 && contains_u32(ap.joiners[:], nr / 2) do continue
		if np, ok := g.privs[nr]; ok {
			cur := node_encryption_key(&t.nodes[nr])
			pub := np.pub
			if bytes_equal(cur, pub[:]) {
				idx = k
				priv = np.priv
				break
			}
		}
		k += 1
	}
	if idx < 0 || idx >= len(path.nodes[start].secrets) do return commit_secret, .State
	ps, dok := decrypt_with_label(priv[:], "UpdatePathNode", ctx_bytes, path.nodes[start].secrets[idx], context.temp_allocator)
	if !dok || len(ps) != NH do return commit_secret, .Crypto
	cur: Secret
	copy(cur[:], ps)
	for i in start ..< len(fdp) {
		ns := derive_secret(cur[:], "node")
		kp, kok := derive_key_pair(ns[:])
		if !kok do return commit_secret, .Crypto
		if !bytes_equal(kp.pub[:], path.nodes[i].encryption_key) do return commit_secret, .Verify
		ng.privs[fdp[i]] = Node_Priv{kp.priv, kp.pub}
		cur = derive_secret(cur[:], "path")
	}
	return cur, .None
}

// ---------------------------------------------------------------------------
// Commit creation

Commit_Result :: struct {
	commit:      []byte, // MLSMessage (PublicMessage)
	welcome:     []byte, // Welcome (raw struct, as DAVE sends it); nil without adds
	has_welcome: bool,
	group:       ^Group, // the next epoch's state, adopt once the commit is accepted
}

// group_commit commits every cached proposal by reference (libdave behaviour:
// inline ratchet tree in the GroupInfo, path only when required).
group_commit :: proc(g: ^Group, force_path := false, allocator := context.allocator) -> (res: Commit_Result, err: Error) {
	ng := group_alloc()
	defer if err != .None do group_destroy(ng)

	props := make([dynamic]^Proposal, 0, len(g.proposals), context.temp_allocator)
	senders := make([dynamic]Sender, 0, len(g.proposals), context.temp_allocator)
	refs := make([dynamic]Proposal_Or_Ref, 0, len(g.proposals), context.temp_allocator)
	for &c in g.proposals {
		append(&props, &c.proposal)
		append(&senders, c.sender)
		append(&refs, Proposal_Or_Ref{is_ref = true, ref = c.ref[:]})
	}
	ng.tree = copy_tree(&g.tree, ng.alloc) or_return
	inherit(g, ng)
	for idx, np in g.privs do ng.privs[idx] = np
	ap := apply_proposals(g, ng, props[:], senders[:], g.my_leaf) or_return
	if ap.removed_self do return res, .State
	t := &ng.tree
	commit := Commit{proposals = refs[:]}
	zero: Secret
	commit_secret := zero
	path_secrets := make([dynamic]Secret, 0, 8, context.temp_allocator)
	fdp: []u32
	if ap.path_required || force_path {
		commit.has_path = true
		leaf_secret: Secret
		crypto.rand_bytes(leaf_secret[:])
		lns := derive_secret(leaf_secret[:], "node")
		leaf_kp, ok := derive_key_pair(lns[:])
		if !ok do return res, .Crypto
		tree_blank_path(t, g.my_leaf)
		fdp = filtered_direct_path(t, g.my_leaf)
		cur := derive_secret(leaf_secret[:], "path")
		nodes := make([]Update_Path_Node, len(fdp), context.temp_allocator)
		for x, i in fdp {
			append(&path_secrets, cur)
			ns := derive_secret(cur[:], "node")
			kp, ok2 := derive_key_pair(ns[:])
			if !ok2 do return res, .Crypto
			t.nodes[x] = Node{kind = .Parent, parent = Parent_Node{encryption_key = clone_bytes(kp.pub[:], ng.alloc)}}
			ng.privs[x] = Node_Priv{kp.priv, kp.pub}
			nodes[i].encryption_key = t.nodes[x].parent.encryption_key
			cur = derive_secret(cur[:], "path")
		}
		commit_secret = cur
		ph: []byte = nil
		mx := g.my_leaf * 2
		for i := len(fdp) - 1; i >= 0; i -= 1 {
			p := fdp[i]
			t.nodes[p].parent.parent_hash = ph
			sib := sibling_of(child_toward(p, mx))
			sh := tree_hash(t, sib)
			h := parent_hash_of(t.nodes[p].parent.encryption_key, ph, sh[:])
			ph = clone_bytes(h[:], ng.alloc)
		}
		old_leaf := leaf_at(&g.tree, g.my_leaf).leaf
		nl := old_leaf
		nl.encryption_key = clone_bytes(leaf_kp.pub[:], ng.alloc)
		nl.source = .Commit
		nl.parent_hash = ph
		nl.not_before = 0
		nl.not_after = 0
		sig, sok := sign_with_label(g.sig_priv[:], "LeafNodeTBS", leaf_node_tbs(nl, g.ctx.group_id, g.my_leaf), ng.alloc)
		if !sok do return res, .Crypto
		nl.signature = sig
		leaf_at(t, g.my_leaf).leaf = nl
		ng.privs[mx] = Node_Priv{leaf_kp.priv, leaf_kp.pub}
		_, ctx_bytes := provisional_context(g, ng, &ap)
		for x, i in fdp {
			cp := sibling_of(child_toward(x, mx))
			res_nodes := resolution(t, cp)
			cts := make([dynamic]Hpke_Ciphertext, 0, len(res_nodes), context.temp_allocator)
			for nr in res_nodes {
				if level(nr) == 0 && contains_u32(ap.joiners[:], nr / 2) do continue
				ct, eok := encrypt_with_label(node_encryption_key(&t.nodes[nr]), "UpdatePathNode", ctx_bytes, path_secrets[i][:], context.temp_allocator)
				if !eok do return res, .Crypto
				append(&cts, ct)
			}
			nodes[i].secrets = cts[:]
		}
		commit.path = Update_Path{leaf = nl, nodes = nodes}
	}

	fc := Framed_Content {
		group_id     = g.ctx.group_id,
		epoch        = g.ctx.epoch,
		sender       = Sender{.Member, g.my_leaf},
		content_type = .Commit,
		commit       = commit,
	}
	content_raw := framed_content_bytes(fc)
	old_ctx_bytes := group_context_bytes(g.ctx)
	tbs := framed_content_tbs(content_raw, fc.sender, old_ctx_bytes)
	signature, sok := sign_with_label(g.sig_priv[:], "FramedContentTBS", tbs, context.temp_allocator)
	if !sok do return res, .Crypto

	gc, _ := provisional_context(g, ng, &ap)
	confirmed := confirmed_hash(g.interim[:], .Public_Message, content_raw, signature)
	gc.confirmed_transcript_hash = confirmed[:]
	ng.ctx = copy_context(gc, ng.alloc) or_return
	ctx_bytes := group_context_bytes(ng.ctx)
	psk_secret := compute_psk_secret(g, ap.psks[:]) or_return
	psk_slice: []byte = psk_secret[:] if len(ap.psks) > 0 else nil
	ng.ks = key_schedule(g.ks.init[:], commit_secret[:], psk_slice, ctx_bytes)
	tag := mac(ng.ks.confirmation_key[:], confirmed[:])
	ng.interim = interim_hash(confirmed[:], tag[:])

	tbm := writer_make()
	w_raw(&tbm, tbs)
	w_raw(&tbm, auth_data_bytes(signature, tag[:], true))
	mtag := mac(g.ks.membership_key[:], tbm.buf[:])

	w := writer_make(allocator)
	w_u16(&w, PROTOCOL_VERSION)
	w_u16(&w, u16(Wire_Format.Public_Message))
	w_raw(&w, content_raw)
	w_vec(&w, signature)
	w_vec(&w, tag[:])
	w_vec(&w, mtag[:])
	res.commit = w.buf[:]

	if len(ap.joiners) > 0 {
		res.welcome = build_welcome(g, ng, &ap, fdp, path_secrets[:], tag[:], allocator) or_return
		res.has_welcome = true
	}
	ng.tree = copy_tree(&ng.tree, ng.alloc) or_return
	prune_privs(ng)
	res.group = ng
	return res, .None
}

@(private)
build_welcome :: proc(g, ng: ^Group, ap: ^Applied, fdp: []u32, path_secrets: []Secret, conf_tag: []byte, allocator: mem.Allocator) -> (out: []byte, err: Error) {
	ext_kp, ok := derive_key_pair(ng.ks.external[:])
	if !ok do return nil, .Crypto
	ep := writer_make()
	w_vec(&ep, ext_kp.pub[:])
	rt := ratchet_tree_bytes(&ng.tree)
	exts := []Extension{{EXT_EXTERNAL_PUB, ep.buf[:]}, {EXT_RATCHET_TREE, rt}}
	gi := Group_Info {
		ctx              = ng.ctx,
		extensions       = exts,
		confirmation_tag = conf_tag,
		signer           = g.my_leaf,
	}
	sig, sok := sign_with_label(g.sig_priv[:], "GroupInfoTBS", group_info_tbs(gi), context.temp_allocator)
	if !sok do return nil, .Crypto
	giw := writer_make()
	w_raw(&giw, group_info_tbs(gi))
	w_vec(&giw, sig)
	key, nonce := welcome_key_nonce(ng.ks.welcome[:])
	egi := aead_seal(key[:], nonce[:], nil, giw.buf[:], context.temp_allocator)

	secrets := make([dynamic]Encrypted_Group_Secrets, 0, len(ap.joiners), context.temp_allocator)
	for j, ji in ap.joiners {
		kp := ap.joiner_kps[ji]
		gs := writer_make()
		w_vec(&gs, ng.ks.joiner[:])
		ps_idx := -1
		for x, i in fdp do if is_ancestor(x, j * 2) {
			ps_idx = i
			break
		}
		w_optional(&gs, ps_idx >= 0)
		if ps_idx >= 0 do w_vec(&gs, path_secrets[ps_idx][:])
		pp := w_begin(&gs)
		for p in ap.psks do w_psk_id(&gs, p)
		w_end(&gs, pp)
		ct, eok := encrypt_with_label(kp.init_key, "Welcome", egi, gs.buf[:], context.temp_allocator)
		if !eok do return nil, .Crypto
		ref := key_package_ref(kp.raw)
		append(&secrets, Encrypted_Group_Secrets{new_member = clone_bytes(ref[:], context.temp_allocator), secrets = ct})
	}
	wel := Welcome {
		cipher_suite         = CIPHER_SUITE,
		secrets              = secrets[:],
		encrypted_group_info = egi,
	}
	w := writer_make(allocator)
	w_welcome(&w, wel)
	return w.buf[:], .None
}

// ---------------------------------------------------------------------------
// Joining from a Welcome

Join_Params :: struct {
	key_package:  ^Key_Package,
	secrets:      ^Key_Package_Secrets,
	sig_priv:     [NSK]byte,
	ratchet_tree: []byte, // out-of-band tree when the GroupInfo has none
	ext_psks:     []Psk_Entry,
}

group_join :: proc(welcome_bytes: []byte, p: Join_Params) -> (res: ^Group, err: Error) {
	ng := group_alloc()
	defer if err != .None do group_destroy(ng)
	a := ng.alloc
	for e in p.ext_psks do group_add_external_psk(ng, e.id, e.secret)
	b := clone_bytes(welcome_bytes, a)
	r := reader_make(b)
	wel := r_welcome(&r, a)
	if !r_done(&r) do return nil, .Decode
	if wel.cipher_suite != CIPHER_SUITE do return nil, .Unsupported
	my_ref := key_package_ref(p.key_package.raw)
	egs: ^Encrypted_Group_Secrets
	for &e in wel.secrets do if bytes_equal(e.new_member, my_ref[:]) do egs = &e
	if egs == nil do return nil, .State
	gs_bytes, ok := decrypt_with_label(p.secrets.init_priv[:], "Welcome", wel.encrypted_group_info, egs.secrets, a)
	if !ok do return nil, .Crypto
	gr := reader_make(gs_bytes)
	gs := r_group_secrets(&gr, a)
	if !r_done(&gr) || len(gs.joiner_secret) != NH do return nil, .Decode

	// psk secret: computed against an empty group (external PSKs only)
	psk_secret := compute_psk_secret(ng, gs.psks) or_return
	copy(ng.ks.joiner[:], gs.joiner_secret)
	zero: Secret
	psk_slice := psk_secret[:] if len(gs.psks) > 0 else zero[:]
	m := kdf_extract(ng.ks.joiner[:], psk_slice)
	ng.ks.welcome = derive_secret(m[:], "welcome")
	key, nonce := welcome_key_nonce(ng.ks.welcome[:])
	gi_bytes, ok2 := aead_open(key[:], nonce[:], nil, wel.encrypted_group_info, a)
	if !ok2 do return nil, .Crypto
	ir := reader_make(gi_bytes)
	gi := r_group_info(&ir, a)
	if !r_done(&ir) do return nil, .Decode
	if gi.ctx.cipher_suite != CIPHER_SUITE || gi.ctx.version != PROTOCOL_VERSION do return nil, .Unsupported

	tree_bytes := p.ratchet_tree
	if e, has := find_extension(gi.extensions, EXT_RATCHET_TREE); has do tree_bytes = e.data
	if tree_bytes == nil do return nil, .State
	ng.tree = parse_ratchet_tree(clone_bytes(tree_bytes, a), a) or_return
	t := &ng.tree

	signer, sok := member_leaf(ng, gi.signer)
	if !sok do return nil, .Verify
	if !verify_with_label(signer.signature_key, "GroupInfoTBS", group_info_tbs(gi), gi.signature) do return nil, .Verify
	tree_validate(t, gi.ctx.group_id, gi.ctx.tree_hash) or_return

	// find our leaf
	found := false
	for l in 0 ..< n_leaves(t) {
		n := leaf_at(t, l)
		if n.kind == .Leaf && bytes_equal(n.leaf.encryption_key, p.key_package.leaf.encryption_key) && bytes_equal(n.leaf.signature_key, p.key_package.leaf.signature_key) {
			ng.my_leaf = l
			found = true
			break
		}
	}
	if !found do return nil, .State
	ng.sig_priv = p.sig_priv
	lp, _ := public_from_private(p.secrets.leaf_priv[:])
	ng.privs[ng.my_leaf * 2] = Node_Priv{p.secrets.leaf_priv, lp}

	if gs.has_path_secret {
		if len(gs.path_secret) != NH do return nil, .Decode
		lca := common_ancestor(ng.my_leaf * 2, gi.signer * 2)
		fdp := filtered_direct_path(t, gi.signer)
		cur: Secret
		copy(cur[:], gs.path_secret)
		started := false
		for x in fdp {
			if x == lca do started = true
			if !started do continue
			ns := derive_secret(cur[:], "node")
			kp, kok := derive_key_pair(ns[:])
			if !kok do return nil, .Crypto
			if !bytes_equal(kp.pub[:], node_encryption_key(&t.nodes[x])) do return nil, .Verify
			ng.privs[x] = Node_Priv{kp.priv, kp.pub}
			cur = derive_secret(cur[:], "path")
		}
		if !started do return nil, .Verify
	}

	ng.ctx = gi.ctx
	ctx_bytes := group_context_bytes(ng.ctx)
	expand_with_label(m[:], "epoch", ctx_bytes, ng.ks.epoch[:])
	key_schedule_from_epoch(&ng.ks)
	tag := mac(ng.ks.confirmation_key[:], ng.ctx.confirmed_transcript_hash)
	if !bytes_equal(tag[:], gi.confirmation_tag) do return nil, .Verify
	ng.interim = interim_hash(ng.ctx.confirmed_transcript_hash, gi.confirmation_tag)
	return ng, .None
}

// ---------------------------------------------------------------------------
// External sender messages (used by the voice gateway; here for tests/fakes)

external_proposal :: proc(group_id: []byte, ep: u64, sender_index: u32, prop: Proposal, sig_priv: []byte, allocator := context.allocator) -> ([]byte, bool) {
	fc := Framed_Content {
		group_id     = group_id,
		epoch        = ep,
		sender       = Sender{.External, sender_index},
		content_type = .Proposal,
		proposal     = prop,
	}
	raw := framed_content_bytes(fc)
	sig, ok := sign_with_label(sig_priv, "FramedContentTBS", framed_content_tbs(raw, fc.sender, nil), context.temp_allocator)
	if !ok do return nil, false
	w := writer_make(allocator)
	w_u16(&w, PROTOCOL_VERSION)
	w_u16(&w, u16(Wire_Format.Public_Message))
	w_raw(&w, raw)
	w_vec(&w, sig)
	return w.buf[:], true
}

// leaf index of the member whose basic credential identity equals id.
find_member :: proc(g: ^Group, identity: []byte) -> (u32, bool) {
	for l in 0 ..< n_leaves(&g.tree) {
		n := leaf_at(&g.tree, l)
		if n.kind == .Leaf && bytes_equal(n.leaf.credential.data, identity) do return l, true
	}
	return 0, false
}
