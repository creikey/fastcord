// Wire structures (RFC 9420). Byte fields of parsed values alias the input
// buffer; arrays of structs are allocated from the given allocator.

CRED_BASIC :: cast(u16) 1;

EXT_APPLICATION_ID :: cast(u16) 1;
EXT_RATCHET_TREE :: cast(u16) 2;
EXT_REQUIRED_CAPABILITIES :: cast(u16) 3;
EXT_EXTERNAL_PUB :: cast(u16) 4;
EXT_EXTERNAL_SENDERS :: cast(u16) 5;

Credential :: struct {
	type: u16;
	data: []u8; // basic: identity; other types: raw vector contents (kept verbatim)
}

Capabilities :: struct {
	versions: []u16;
	cipher_suites: []u16;
	extensions: []u16;
	proposals: []u16;
	credentials: []u16;
}

Extension :: struct {
	type: u16;
	data: []u8;
}

Leaf_Node_Source :: enum u8 {
	Reserved :: 0;
	Key_Package :: 1;
	Update :: 2;
	Commit :: 3;
}

Leaf_Node :: struct {
	encryption_key: []u8;
	signature_key: []u8;
	credential: Credential;
	capabilities: Capabilities;
	source: Leaf_Node_Source;
	not_before: u64;
	not_after: u64;
	parent_hash: []u8;
	extensions: []Extension;
	signature: []u8;
}

Parent_Node :: struct {
	encryption_key: []u8;
	parent_hash: []u8;
	unmerged_leaves: []u32;
}

Key_Package :: struct {
	version: u16;
	cipher_suite: u16;
	init_key: []u8;
	leaf: Leaf_Node;
	extensions: []Extension;
	signature: []u8;
	raw: []u8; // full serialization (for KeyPackageRef)
}

Proposal_Type :: enum u16 {
	Add :: 1;
	Update :: 2;
	Remove :: 3;
	Psk :: 4;
	Reinit :: 5;
	External_Init :: 6;
	Group_Context_Extensions :: 7;
}

Psk_Id :: struct {
	type: u8; // 1 external, 2 resumption
	id: []u8;
	usage: u8;
	group_id: []u8;
	epoch: u64;
	nonce: []u8;
}

Proposal :: struct {
	type: Proposal_Type;
	add: Key_Package;
	update: Leaf_Node;
	remove_: u32;
	psk: Psk_Id;
	extensions: []Extension; // GroupContextExtensions
	raw: []u8;
}

Proposal_Or_Ref :: struct {
	is_ref: bool;
	ref: []u8;
	proposal: Proposal;
}

Update_Path_Node :: struct {
	encryption_key: []u8;
	secrets: []Hpke_Ciphertext;
}

Update_Path :: struct {
	leaf: Leaf_Node;
	nodes: []Update_Path_Node;
}

Commit :: struct {
	proposals: []Proposal_Or_Ref;
	has_path: bool;
	path: Update_Path;
}

Sender_Type :: enum u8 {
	Reserved :: 0;
	Member :: 1;
	External :: 2;
	New_Member_Proposal :: 3;
	New_Member_Commit :: 4;
}

Sender :: struct {
	type: Sender_Type;
	index: u32;
}

Content_Type :: enum u8 {
	Reserved :: 0;
	Application :: 1;
	Proposal :: 2;
	Commit :: 3;
}

Framed_Content :: struct {
	group_id: []u8;
	epoch: u64;
	sender: Sender;
	authenticated_data: []u8;
	content_type: Content_Type;
	application_data: []u8;
	proposal: Proposal;
	commit: Commit;
	raw: []u8;
}

Public_Message :: struct {
	content: Framed_Content;
	signature: []u8;
	confirmation_tag: []u8;
	membership_tag: []u8;
}

Wire_Format :: enum u16 {
	Reserved :: 0;
	Public_Message :: 1;
	Private_Message :: 2;
	Welcome :: 3;
	Group_Info :: 4;
	Key_Package :: 5;
}

Group_Context :: struct {
	version: u16;
	cipher_suite: u16;
	group_id: []u8;
	epoch: u64;
	tree_hash: []u8;
	confirmed_transcript_hash: []u8;
	extensions: []Extension;
}

Group_Info :: struct {
	ctx: Group_Context;
	extensions: []Extension;
	confirmation_tag: []u8;
	signer: u32;
	signature: []u8;
}

Group_Secrets :: struct {
	joiner_secret: []u8;
	has_path_secret: bool;
	path_secret: []u8;
	psks: []Psk_Id;
}

Encrypted_Group_Secrets :: struct {
	new_member: []u8;
	secrets: Hpke_Ciphertext;
}

Welcome :: struct {
	cipher_suite: u16;
	secrets: []Encrypted_Group_Secrets;
	encrypted_group_info: []u8;
}

External_Sender :: struct {
	signature_key: []u8;
	credential: Credential;
}

MLS_Message :: struct {
	version: u16;
	wire_format: Wire_Format;
	public: Public_Message;
	welcome: Welcome;
	group_info: Group_Info;
	key_package: Key_Package;
}

// ---------------------------------------------------------------------------
// Encoding

w_u16_list :: (w: *Writer, l: []u16) {
	p := w_begin(w);
	for v: l { w_u16(w, v); }
	w_end(w, p);
}

w_u32_list :: (w: *Writer, l: []u32) {
	p := w_begin(w);
	for v: l { w_u32(w, v); }
	w_end(w, p);
}

w_credential :: (w: *Writer, c: Credential) {
	w_u16(w, c.type);
	w_vec(w, c.data);
}

w_capabilities :: (w: *Writer, c: Capabilities) {
	w_u16_list(w, c.versions);
	w_u16_list(w, c.cipher_suites);
	w_u16_list(w, c.extensions);
	w_u16_list(w, c.proposals);
	w_u16_list(w, c.credentials);
}

w_extensions :: (w: *Writer, exts: []Extension) {
	p := w_begin(w);
	for e: exts {
		w_u16(w, e.type);
		w_vec(w, e.data);
	}
	w_end(w, p);
}

w_leaf_node_content :: (w: *Writer, ln: Leaf_Node) {
	w_vec(w, ln.encryption_key);
	w_vec(w, ln.signature_key);
	w_credential(w, ln.credential);
	w_capabilities(w, ln.capabilities);
	w_u8(w, cast(u8) ln.source);
	if ln.source == {
	case .Key_Package;
		w_u64(w, ln.not_before);
		w_u64(w, ln.not_after);
	case .Commit;
		w_vec(w, ln.parent_hash);
	}
	w_extensions(w, ln.extensions);
}

w_leaf_node :: (w: *Writer, ln: Leaf_Node) {
	w_leaf_node_content(w, ln);
	w_vec(w, ln.signature);
}

leaf_node_tbs :: (ln: Leaf_Node, group_id: []u8, leaf_index: u32) -> []u8 {
	w := writer_make();
	w_leaf_node_content(*w, ln);
	if ln.source == .Update || ln.source == .Commit {
		w_vec(*w, group_id);
		w_u32(*w, leaf_index);
	}
	return w.buf;
}

w_parent_node :: (w: *Writer, p: Parent_Node) {
	w_vec(w, p.encryption_key);
	w_vec(w, p.parent_hash);
	w_u32_list(w, p.unmerged_leaves);
}

key_package_tbs :: (kp: Key_Package) -> []u8 {
	w := writer_make();
	w_u16(*w, kp.version);
	w_u16(*w, kp.cipher_suite);
	w_vec(*w, kp.init_key);
	w_leaf_node(*w, kp.leaf);
	w_extensions(*w, kp.extensions);
	return w.buf;
}

w_key_package :: (w: *Writer, kp: Key_Package) {
	w_raw(w, key_package_tbs(kp));
	w_vec(w, kp.signature);
}

w_psk_id :: (w: *Writer, p: Psk_Id) {
	w_u8(w, p.type);
	if p.type == {
	case 1;
		w_vec(w, p.id);
	case 2;
		w_u8(w, p.usage);
		w_vec(w, p.group_id);
		w_u64(w, p.epoch);
	}
	w_vec(w, p.nonce);
}

w_proposal :: (w: *Writer, p: Proposal) {
	w_u16(w, cast(u16) p.type);
	if p.type == {
	case .Add;
		w_key_package(w, p.add);
	case .Update;
		w_leaf_node(w, p.update);
	case .Remove;
		w_u32(w, p.remove_);
	case .Psk;
		w_psk_id(w, p.psk);
	case .Group_Context_Extensions;
		w_extensions(w, p.extensions);
	case;
		w_raw(w, p.raw);
	}
}

w_hpke_ciphertext :: (w: *Writer, c: Hpke_Ciphertext) {
	w_vec(w, c.kem_output);
	w_vec(w, c.ciphertext);
}

w_commit :: (w: *Writer, c: Commit) {
	p := w_begin(w);
	for por: c.proposals {
		if por.is_ref {
			w_u8(w, 2);
			w_vec(w, por.ref);
		} else {
			w_u8(w, 1);
			w_proposal(w, por.proposal);
		}
	}
	w_end(w, p);
	w_optional(w, c.has_path);
	if c.has_path {
		w_leaf_node(w, c.path.leaf);
		q := w_begin(w);
		for n: c.path.nodes {
			w_vec(w, n.encryption_key);
			s := w_begin(w);
			for ct: n.secrets { w_hpke_ciphertext(w, ct); }
			w_end(w, s);
		}
		w_end(w, q);
	}
}

w_sender :: (w: *Writer, s: Sender) {
	w_u8(w, cast(u8) s.type);
	if s.type == .Member || s.type == .External { w_u32(w, s.index); }
}

framed_content_bytes :: (fc: Framed_Content) -> []u8 {
	w := writer_make();
	w_vec(*w, fc.group_id);
	w_u64(*w, fc.epoch);
	w_sender(*w, fc.sender);
	w_vec(*w, fc.authenticated_data);
	w_u8(*w, cast(u8) fc.content_type);
	if fc.content_type == {
	case .Application;
		w_vec(*w, fc.application_data);
	case .Proposal;
		w_proposal(*w, fc.proposal);
	case .Commit;
		w_commit(*w, fc.commit);
	}
	return w.buf;
}

w_group_context :: (w: *Writer, gc: Group_Context) {
	w_u16(w, gc.version);
	w_u16(w, gc.cipher_suite);
	w_vec(w, gc.group_id);
	w_u64(w, gc.epoch);
	w_vec(w, gc.tree_hash);
	w_vec(w, gc.confirmed_transcript_hash);
	w_extensions(w, gc.extensions);
}

group_context_bytes :: (gc: Group_Context) -> []u8 {
	w := writer_make();
	w_group_context(*w, gc);
	return w.buf;
}

group_info_tbs :: (gi: Group_Info) -> []u8 {
	w := writer_make();
	w_group_context(*w, gi.ctx);
	w_extensions(*w, gi.extensions);
	w_vec(*w, gi.confirmation_tag);
	w_u32(*w, gi.signer);
	return w.buf;
}

w_external_sender :: (w: *Writer, e: External_Sender) {
	w_vec(w, e.signature_key);
	w_credential(w, e.credential);
}

// ---------------------------------------------------------------------------
// Decoding. Arrays go to context.allocator.

r_u16_list :: (r: *Reader) -> []u16 {
	sub := r_sub(r);
	if sub.data.count % 2 != 0 {
		r_fail(r);
		return .[];
	}
	out := NewArray(sub.data.count / 2, u16, false);
	for * out it.* = r_u16(*sub);
	return out;
}

r_u32_list :: (r: *Reader) -> []u32 {
	sub := r_sub(r);
	if sub.data.count % 4 != 0 {
		r_fail(r);
		return .[];
	}
	out := NewArray(sub.data.count / 4, u32, false);
	for * out it.* = r_u32(*sub);
	return out;
}

r_credential :: (r: *Reader) -> Credential {
	c: Credential;
	c.type = r_u16(r);
	c.data = r_vec(r);
	return c;
}

r_capabilities :: (r: *Reader) -> Capabilities {
	c: Capabilities;
	c.versions = r_u16_list(r);
	c.cipher_suites = r_u16_list(r);
	c.extensions = r_u16_list(r);
	c.proposals = r_u16_list(r);
	c.credentials = r_u16_list(r);
	return c;
}

r_extensions :: (r: *Reader) -> []Extension {
	sub := r_sub(r);
	out: [..]Extension;
	while r_ok(*sub) && r_left(*sub) > 0 {
		e := array_add(*out);
		e.type = r_u16(*sub);
		e.data = r_vec(*sub);
	}
	if !r_ok(*sub) r_fail(r);
	// duplicates are invalid
	for i: 0..out.count-1 for j: i+1..out.count-1 if out[i].type == out[j].type r_fail(r);
	return out;
}

r_leaf_node :: (r: *Reader) -> Leaf_Node {
	ln: Leaf_Node;
	ln.encryption_key = r_vec(r);
	ln.signature_key = r_vec(r);
	ln.credential = r_credential(r);
	ln.capabilities = r_capabilities(r);
	ln.source = cast(Leaf_Node_Source) r_u8(r);
	if ln.source == {
	case .Key_Package;
		ln.not_before = r_u64(r);
		ln.not_after = r_u64(r);
	case .Commit;
		ln.parent_hash = r_vec(r);
	case .Update;
	case;
		r_fail(r);
	}
	ln.extensions = r_extensions(r);
	ln.signature = r_vec(r);
	return ln;
}

r_parent_node :: (r: *Reader) -> Parent_Node {
	p: Parent_Node;
	p.encryption_key = r_vec(r);
	p.parent_hash = r_vec(r);
	p.unmerged_leaves = r_u32_list(r);
	return p;
}

r_key_package :: (r: *Reader) -> Key_Package {
	kp: Key_Package;
	start := r.pos;
	kp.version = r_u16(r);
	kp.cipher_suite = r_u16(r);
	kp.init_key = r_vec(r);
	kp.leaf = r_leaf_node(r);
	kp.extensions = r_extensions(r);
	kp.signature = r_vec(r);
	if r_ok(r) kp.raw = r_since(r, start);
	return kp;
}

r_psk_id :: (r: *Reader) -> Psk_Id {
	p: Psk_Id;
	p.type = r_u8(r);
	if p.type == {
	case 1;
		p.id = r_vec(r);
	case 2;
		p.usage = r_u8(r);
		p.group_id = r_vec(r);
		p.epoch = r_u64(r);
	case;
		r_fail(r);
	}
	p.nonce = r_vec(r);
	return p;
}

r_proposal :: (r: *Reader) -> Proposal {
	p: Proposal;
	start := r.pos;
	p.type = cast(Proposal_Type) r_u16(r);
	if p.type == {
	case .Add;
		p.add = r_key_package(r);
	case .Update;
		p.update = r_leaf_node(r);
	case .Remove;
		p.remove_ = r_u32(r);
	case .Psk;
		p.psk = r_psk_id(r);
	case .Reinit;
		r_vec(r);
		r_u16(r);
		r_u16(r);
		r_extensions(r);
	case .External_Init;
		r_vec(r);
	case .Group_Context_Extensions;
		p.extensions = r_extensions(r);
	case;
		r_fail(r); // unknown proposal types cannot be skipped (no length prefix)
	}
	if r_ok(r) p.raw = r_since(r, start);
	return p;
}

r_hpke_ciphertext :: (r: *Reader) -> Hpke_Ciphertext {
	c: Hpke_Ciphertext;
	c.kem_output = r_vec(r);
	c.ciphertext = r_vec(r);
	return c;
}

r_commit :: (r: *Reader) -> Commit {
	c: Commit;
	sub := r_sub(r);
	props: [..]Proposal_Or_Ref;
	while r_ok(*sub) && r_left(*sub) > 0 {
		por := array_add(*props);
		if r_u8(*sub) == {
		case 1;
			por.proposal = r_proposal(*sub);
		case 2;
			por.is_ref = true;
			por.ref = r_vec(*sub);
		case;
			r_fail(*sub);
		}
	}
	if !r_ok(*sub) r_fail(r);
	c.proposals = props;
	c.has_path = r_optional(r);
	if c.has_path {
		c.path.leaf = r_leaf_node(r);
		ns := r_sub(r);
		nodes: [..]Update_Path_Node;
		while r_ok(*ns) && r_left(*ns) > 0 {
			n := array_add(*nodes);
			n.encryption_key = r_vec(*ns);
			ss := r_sub(*ns);
			cts: [..]Hpke_Ciphertext;
			while r_ok(*ss) && r_left(*ss) > 0 array_add(*cts, r_hpke_ciphertext(*ss));
			if !r_ok(*ss) r_fail(*ns);
			n.secrets = cts;
		}
		if !r_ok(*ns) r_fail(r);
		c.path.nodes = nodes;
	}
	return c;
}

r_sender :: (r: *Reader) -> Sender {
	s: Sender;
	s.type = cast(Sender_Type) r_u8(r);
	if s.type == {
	case .Member; #through;
	case .External;
		s.index = r_u32(r);
	case .New_Member_Commit; #through;
	case .New_Member_Proposal;
	case;
		r_fail(r);
	}
	return s;
}

r_framed_content :: (r: *Reader) -> Framed_Content {
	fc: Framed_Content;
	start := r.pos;
	fc.group_id = r_vec(r);
	fc.epoch = r_u64(r);
	fc.sender = r_sender(r);
	fc.authenticated_data = r_vec(r);
	fc.content_type = cast(Content_Type) r_u8(r);
	if fc.content_type == {
	case .Application;
		fc.application_data = r_vec(r);
	case .Proposal;
		fc.proposal = r_proposal(r);
	case .Commit;
		fc.commit = r_commit(r);
	case;
		r_fail(r);
	}
	if r_ok(r) fc.raw = r_since(r, start);
	return fc;
}

r_public_message :: (r: *Reader) -> Public_Message {
	pm: Public_Message;
	pm.content = r_framed_content(r);
	pm.signature = r_vec(r);
	if pm.content.content_type == .Commit pm.confirmation_tag = r_vec(r);
	if pm.content.sender.type == .Member pm.membership_tag = r_vec(r);
	return pm;
}

r_group_context :: (r: *Reader) -> Group_Context {
	gc: Group_Context;
	gc.version = r_u16(r);
	gc.cipher_suite = r_u16(r);
	gc.group_id = r_vec(r);
	gc.epoch = r_u64(r);
	gc.tree_hash = r_vec(r);
	gc.confirmed_transcript_hash = r_vec(r);
	gc.extensions = r_extensions(r);
	return gc;
}

r_group_info :: (r: *Reader) -> Group_Info {
	gi: Group_Info;
	gi.ctx = r_group_context(r);
	gi.extensions = r_extensions(r);
	gi.confirmation_tag = r_vec(r);
	gi.signer = r_u32(r);
	gi.signature = r_vec(r);
	return gi;
}

r_group_secrets :: (r: *Reader) -> Group_Secrets {
	gs: Group_Secrets;
	gs.joiner_secret = r_vec(r);
	gs.has_path_secret = r_optional(r);
	if gs.has_path_secret gs.path_secret = r_vec(r);
	sub := r_sub(r);
	psks: [..]Psk_Id;
	while r_ok(*sub) && r_left(*sub) > 0 array_add(*psks, r_psk_id(*sub));
	if !r_ok(*sub) r_fail(r);
	gs.psks = psks;
	return gs;
}

r_welcome :: (r: *Reader) -> Welcome {
	w: Welcome;
	w.cipher_suite = r_u16(r);
	sub := r_sub(r);
	list: [..]Encrypted_Group_Secrets;
	while r_ok(*sub) && r_left(*sub) > 0 {
		e := array_add(*list);
		e.new_member = r_vec(*sub);
		e.secrets = r_hpke_ciphertext(*sub);
	}
	if !r_ok(*sub) r_fail(r);
	w.secrets = list;
	w.encrypted_group_info = r_vec(r);
	return w;
}

w_welcome :: (w: *Writer, wel: Welcome) {
	w_u16(w, wel.cipher_suite);
	p := w_begin(w);
	for wel.secrets {
		w_vec(w, it.new_member);
		w_hpke_ciphertext(w, it.secrets);
	}
	w_end(w, p);
	w_vec(w, wel.encrypted_group_info);
}

r_external_sender :: (r: *Reader) -> External_Sender {
	e: External_Sender;
	e.signature_key = r_vec(r);
	e.credential = r_credential(r);
	return e;
}

// parse_mls_message decodes a complete MLSMessage (must consume all bytes).
parse_mls_message :: (b: []u8) -> MLS_Message, Error {
	m: MLS_Message;
	r := reader_make(b);
	m.version = r_u16(*r);
	m.wire_format = cast(Wire_Format) r_u16(*r);
	if !r_ok(*r) return m, .Decode;
	if m.version != PROTOCOL_VERSION return m, .Unsupported;
	if m.wire_format == {
	case .Public_Message;  m.public = r_public_message(*r);
	case .Welcome;         m.welcome = r_welcome(*r);
	case .Group_Info;      m.group_info = r_group_info(*r);
	case .Key_Package;     m.key_package = r_key_package(*r);
	case .Private_Message; return m, .Unsupported;
	case;                  return m, .Decode;
	}
	if !r_done(*r) return m, .Decode;
	return m, .None;
}

find_extension :: (exts: []Extension, type: u16) -> Extension, bool {
	for exts if it.type == type return it, true;
	return .{}, false;
}

// r_mls_message_raw consumes one MLSMessage from r (inside a vector of
// messages) and returns its bytes.
r_mls_message_raw :: (r: *Reader) -> []u8 {
	start := r.pos;
	version := r_u16(r);
	wf := cast(Wire_Format) r_u16(r);
	if !r_ok(r) || version != PROTOCOL_VERSION {
		r_fail(r);
		return .[];
	}
	push_allocator(temp);
	if wf == {
	case .Public_Message; r_public_message(r);
	case .Welcome;        r_welcome(r);
	case .Group_Info;     r_group_info(r);
	case .Key_Package;    r_key_package(r);
	case;                 r_fail(r);
	}
	if !r_ok(r) return .[];
	return r_since(r, start);
}
