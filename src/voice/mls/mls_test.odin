package mls

import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:testing"

// Test vectors: github.com/mlswg/mls-implementations/test-vectors, filtered to
// cipher suite 2 (testdata/mls).

@(private = "file")
load :: proc(name: string) -> json.Array {
	path := fmt.tprintf("%s/testdata/mls/%s", #directory + "/..", name)
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil do return nil
	v, jerr := json.parse_bytes(data, parse_integers = true, allocator = context.temp_allocator)
	if jerr != nil do return nil
	return v.(json.Array) or_else nil
}

@(private = "file")
obj :: proc(v: json.Value) -> json.Object {return v.(json.Object) or_else nil}

@(private = "file")
hx :: proc(o: json.Object, k: string) -> []byte {
	s, ok := o[k].(json.String)
	if !ok do return nil
	b, _ := hex.decode(transmute([]byte)string(s), context.temp_allocator)
	if b == nil do return []byte{}
	return b
}

@(private = "file")
num :: proc(o: json.Object, k: string) -> i64 {
	#partial switch v in o[k] {
	case json.Integer:
		return v
	case json.Float:
		return i64(v)
	case json.String:
		n: i64 = 0
		for c in v do n = n * 10 + i64(c - '0')
		return n
	}
	return -1
}

@(test)
test_crypto_basics :: proc(t: ^testing.T) {
	arr := load("crypto-basics.json")
	testing.expect(t, len(arr) == 1)
	for tv in arr {
		o := obj(tv)
		rh := obj(o["ref_hash"])
		label := string(rh["label"].(json.String))
		out := ref_hash(label, hx(rh, "value"))
		testing.expect(t, bytes_equal(out[:], hx(rh, "out")), "ref_hash")

		ew := obj(o["expand_with_label"])
		dst := make([]byte, num(ew, "length"), context.temp_allocator)
		expand_with_label(hx(ew, "secret"), string(ew["label"].(json.String)), hx(ew, "context"), dst)
		testing.expect(t, bytes_equal(dst, hx(ew, "out")), "expand_with_label")

		ds := obj(o["derive_secret"])
		d := derive_secret(hx(ds, "secret"), string(ds["label"].(json.String)))
		testing.expect(t, bytes_equal(d[:], hx(ds, "out")), "derive_secret")

		dt := obj(o["derive_tree_secret"])
		dd := make([]byte, num(dt, "length"), context.temp_allocator)
		derive_tree_secret(hx(dt, "secret"), string(dt["label"].(json.String)), u32(num(dt, "generation")), dd)
		testing.expect(t, bytes_equal(dd, hx(dt, "out")), "derive_tree_secret")

		sw := obj(o["sign_with_label"])
		sl := string(sw["label"].(json.String))
		testing.expect(t, verify_with_label(hx(sw, "pub"), sl, hx(sw, "content"), hx(sw, "signature")), "verify_with_label")
		sig, ok := sign_with_label(hx(sw, "priv"), sl, hx(sw, "content"), context.temp_allocator)
		testing.expect(t, ok && verify_with_label(hx(sw, "pub"), sl, hx(sw, "content"), sig), "sign roundtrip")

		el := obj(o["encrypt_with_label"])
		ell := string(el["label"].(json.String))
		pt, dok := decrypt_with_label(hx(el, "priv"), ell, hx(el, "context"), Hpke_Ciphertext{hx(el, "kem_output"), hx(el, "ciphertext")}, context.temp_allocator)
		testing.expect(t, dok && bytes_equal(pt, hx(el, "plaintext")), "decrypt_with_label")
		ct, eok := encrypt_with_label(hx(el, "pub"), ell, hx(el, "context"), hx(el, "plaintext"), context.temp_allocator)
		pt2, dok2 := decrypt_with_label(hx(el, "priv"), ell, hx(el, "context"), ct, context.temp_allocator)
		testing.expect(t, eok && dok2 && bytes_equal(pt2, hx(el, "plaintext")), "encrypt roundtrip")
	}
}

@(test)
test_tree_math :: proc(t: ^testing.T) {
	arr := load("tree-math.json")
	testing.expect(t, len(arr) > 0)
	for tv in arr {
		o := obj(tv)
		nl := u32(num(o, "n_leaves"))
		testing.expect(t, node_width(nl) == u32(num(o, "n_nodes")))
		testing.expect(t, root(nl) == u32(num(o, "root")))
		lefts := o["left"].(json.Array)
		rights := o["right"].(json.Array)
		parents := o["parent"].(json.Array)
		sibs := o["sibling"].(json.Array)
		r := root(nl)
		for i in 0 ..< len(lefts) {
			x := u32(i)
			if l, ok := lefts[i].(json.Integer); ok do testing.expect(t, left(x) == u32(l))
			if rr, ok := rights[i].(json.Integer); ok do testing.expect(t, right(x) == u32(rr))
			if p, ok := parents[i].(json.Integer); ok {
				testing.expect(t, x != r && parent_of(x) == u32(p))
			}
			if s, ok := sibs[i].(json.Integer); ok do testing.expect(t, sibling_of(x) == u32(s))
		}
	}
}

@(test)
test_key_schedule :: proc(t: ^testing.T) {
	arr := load("key-schedule.json")
	testing.expect(t, len(arr) == 1)
	for tv in arr {
		o := obj(tv)
		init := hx(o, "initial_init_secret")
		for ev in o["epochs"].(json.Array) {
			e := obj(ev)
			gcb := hx(e, "group_context")
			// group context encoding round trip
			r := reader_make(gcb)
			gc := r_group_context(&r, context.temp_allocator)
			testing.expect(t, r_done(&r) && bytes_equal(group_context_bytes(gc), gcb), "group context codec")
			ks := key_schedule(init, hx(e, "commit_secret"), hx(e, "psk_secret"), gcb)
			testing.expect(t, bytes_equal(ks.joiner[:], hx(e, "joiner_secret")), "joiner")
			testing.expect(t, bytes_equal(ks.welcome[:], hx(e, "welcome_secret")), "welcome")
			testing.expect(t, bytes_equal(ks.init[:], hx(e, "init_secret")), "init")
			testing.expect(t, bytes_equal(ks.sender_data[:], hx(e, "sender_data_secret")), "sender data")
			testing.expect(t, bytes_equal(ks.encryption[:], hx(e, "encryption_secret")), "encryption")
			testing.expect(t, bytes_equal(ks.exporter[:], hx(e, "exporter_secret")), "exporter")
			testing.expect(t, bytes_equal(ks.epoch_authenticator[:], hx(e, "epoch_authenticator")), "authenticator")
			testing.expect(t, bytes_equal(ks.external[:], hx(e, "external_secret")), "external")
			testing.expect(t, bytes_equal(ks.confirmation_key[:], hx(e, "confirmation_key")), "confirm")
			testing.expect(t, bytes_equal(ks.membership_key[:], hx(e, "membership_key")), "membership")
			testing.expect(t, bytes_equal(ks.resumption_psk[:], hx(e, "resumption_psk")), "resumption")
			ekp, ok := derive_key_pair(ks.external[:])
			testing.expect(t, ok && bytes_equal(ekp.pub[:], hx(e, "external_pub")), "external_pub")
			ex := obj(e["exporter"])
			g: Group
			g.ks = ks
			dst := make([]byte, num(ex, "length"), context.temp_allocator)
			exporter(&g, string(ex["label"].(json.String)), hx(ex, "context"), dst)
			testing.expect(t, bytes_equal(dst, hx(ex, "secret")), "exporter value")
			init = clone_bytes(ks.init[:], context.temp_allocator)
		}
	}
}

@(test)
test_transcript_hashes :: proc(t: ^testing.T) {
	for tv in load("transcript-hashes.json") {
		o := obj(tv)
		ac := hx(o, "authenticated_content")
		r := reader_make(ac)
		wf := r_u16(&r)
		fc := r_framed_content(&r, context.temp_allocator)
		sig := r_vec(&r)
		tag := r_vec(&r)
		testing.expect(t, r_done(&r) && wf == 1)
		testing.expect(t, bytes_equal(framed_content_bytes(fc), fc.raw), "framed content re-encode")
		ch := confirmed_hash(hx(o, "interim_transcript_hash_before"), Wire_Format(wf), fc.raw, sig)
		testing.expect(t, bytes_equal(ch[:], hx(o, "confirmed_transcript_hash_after")), "confirmed")
		m := mac(hx(o, "confirmation_key"), ch[:])
		testing.expect(t, bytes_equal(m[:], tag), "confirmation tag")
		ih := interim_hash(ch[:], tag)
		testing.expect(t, bytes_equal(ih[:], hx(o, "interim_transcript_hash_after")), "interim")
	}
}

@(test)
test_tree_validation :: proc(t: ^testing.T) {
	arr := load("tree-validation.json")
	testing.expect(t, len(arr) > 0)
	for tv in arr {
		o := obj(tv)
		tb := hx(o, "tree")
		tree, err := parse_ratchet_tree(tb, context.temp_allocator)
		testing.expect(t, err == .None, "parse tree")
		if err != .None do continue
		testing.expect(t, bytes_equal(ratchet_tree_bytes(&tree), tb), "tree re-encode")
		hashes := o["tree_hashes"].(json.Array)
		ress := o["resolutions"].(json.Array)
		testing.expect(t, len(hashes) == len(tree.nodes))
		for i in 0 ..< min(len(hashes), len(tree.nodes)) {
			h := tree_hash(&tree, u32(i))
			want, _ := hex.decode(transmute([]byte)string(hashes[i].(json.String)), context.temp_allocator)
			testing.expectf(t, bytes_equal(h[:], want), "tree hash node %d", i)
			res := resolution(&tree, u32(i))
			wr := ress[i].(json.Array)
			ok := len(res) == len(wr)
			if ok do for j in 0 ..< len(res) do if u32(wr[j].(json.Integer)) != res[j] do ok = false
			testing.expectf(t, ok, "resolution node %d", i)
		}
		rh := tree_hash(&tree, root(n_leaves(&tree)))
		testing.expect(t, tree_validate(&tree, hx(o, "group_id"), rh[:]) == .None, "tree valid")
	}
}

@(test)
test_welcome_vector :: proc(t: ^testing.T) {
	for tv in load("welcome.json") {
		o := obj(tv)
		km, kerr := parse_mls_message(hx(o, "key_package"), context.temp_allocator)
		testing.expect(t, kerr == .None && km.wire_format == .Key_Package)
		testing.expect(t, validate_key_package(&km.key_package) == .None, "kp valid")
		wm, werr := parse_mls_message(hx(o, "welcome"), context.temp_allocator)
		testing.expect(t, werr == .None && wm.wire_format == .Welcome)
		ref := key_package_ref(km.key_package.raw)
		egs: ^Encrypted_Group_Secrets
		for &e in wm.welcome.secrets do if bytes_equal(e.new_member, ref[:]) do egs = &e
		testing.expect(t, egs != nil, "kp ref")
		if egs == nil do continue
		gsb, ok := decrypt_with_label(hx(o, "init_priv"), "Welcome", wm.welcome.encrypted_group_info, egs.secrets, context.temp_allocator)
		testing.expect(t, ok, "group secrets")
		gr := reader_make(gsb)
		gs := r_group_secrets(&gr, context.temp_allocator)
		ks: Epoch_Secrets
		copy(ks.joiner[:], gs.joiner_secret)
		zero: Secret
		m := kdf_extract(ks.joiner[:], zero[:])
		ws := derive_secret(m[:], "welcome")
		key, nonce := welcome_key_nonce(ws[:])
		gib, ok2 := aead_open(key[:], nonce[:], nil, wm.welcome.encrypted_group_info, context.temp_allocator)
		testing.expect(t, ok2, "group info decrypt")
		ir := reader_make(gib)
		gi := r_group_info(&ir, context.temp_allocator)
		testing.expect(t, r_done(&ir))
		testing.expect(t, verify_with_label(hx(o, "signer_pub"), "GroupInfoTBS", group_info_tbs(gi), gi.signature), "gi signature")
		expand_with_label(m[:], "epoch", group_context_bytes(gi.ctx), ks.epoch[:])
		key_schedule_from_epoch(&ks)
		tag := mac(ks.confirmation_key[:], gi.ctx.confirmed_transcript_hash)
		testing.expect(t, bytes_equal(tag[:], gi.confirmation_tag), "confirmation tag")
	}
}

@(test)
test_message_protection_public :: proc(t: ^testing.T) {
	for tv in load("message-protection.json") {
		o := obj(tv)
		g := group_alloc()
		defer group_destroy(g)
		g.ctx = Group_Context {
			version                   = 1,
			cipher_suite              = 2,
			group_id                  = hx(o, "group_id"),
			epoch                     = u64(num(o, "epoch")),
			tree_hash                 = hx(o, "tree_hash"),
			confirmed_transcript_hash = hx(o, "confirmed_transcript_hash"),
		}
		copy(g.ks.membership_key[:], hx(o, "membership_key"))
		// one-leaf tree with the signer at index 1 (vectors use sender leaf 1)
		g.tree.nodes = make([dynamic]Node, 3, g.alloc)
		g.tree.nodes[2] = Node{kind = .Leaf, leaf = Leaf_Node{signature_key = hx(o, "signature_pub")}}
		for k in ([]string{"proposal_pub", "commit_pub", "application_pub"}) {
			b := hx(o, k)
			if len(b) == 0 do continue
			m, err := parse_mls_message(b, context.temp_allocator)
			testing.expectf(t, err == .None, "%s parse", k)
			if err != .None do continue
			testing.expectf(t, verify_public_message(g, &m.public) == .None, "%s verify", k)
		}
	}
}

@(private = "file")
run_passive :: proc(t: ^testing.T, file: string) -> (ran: int) {
	for tv, ti in load(file) {
		o := obj(tv)
		km, kerr := parse_mls_message(hx(o, "key_package"), context.temp_allocator)
		testing.expect(t, kerr == .None)
		if kerr != .None do continue
		secrets: Key_Package_Secrets
		copy(secrets.init_priv[:], hx(o, "init_priv"))
		copy(secrets.leaf_priv[:], hx(o, "encryption_priv"))
		jp := Join_Params {
			key_package  = &km.key_package,
			secrets      = &secrets,
			ratchet_tree = hx(o, "ratchet_tree") if o["ratchet_tree"] != nil else nil,
		}
		copy(jp.sig_priv[:], hx(o, "signature_priv"))
		psks := make([dynamic]Psk_Entry, 0, 1, context.temp_allocator)
		for pv in o["external_psks"].(json.Array) {
			po := obj(pv)
			append(&psks, Psk_Entry{hx(po, "psk_id"), hx(po, "psk")})
		}
		jp.ext_psks = psks[:]
		wb := hx(o, "welcome")
		g, err := group_join(wb[4:], jp)
		testing.expectf(t, err == .None, "%s[%d] join: %v", file, ti, err)
		if err != .None do continue
		auth := epoch_authenticator(g)
		testing.expectf(t, bytes_equal(auth[:], hx(o, "initial_epoch_authenticator")), "%s[%d] initial authenticator", file, ti)
		for ev, ei in o["epochs"].(json.Array) {
			e := obj(ev)
			for pv in e["proposals"].(json.Array) {
				pb, _ := hex.decode(transmute([]byte)string(pv.(json.String)), context.temp_allocator)
				_, _, perr := group_cache_proposal(g, pb)
				testing.expectf(t, perr == .None, "%s[%d] epoch %d proposal: %v", file, ti, ei, perr)
			}
			ng, cerr := group_process_commit(g, hx(e, "commit"))
			testing.expectf(t, cerr == .None, "%s[%d] epoch %d commit: %v", file, ti, ei, cerr)
			if cerr != .None do break
			group_destroy(g)
			g = ng
			a := epoch_authenticator(g)
			testing.expectf(t, bytes_equal(a[:], hx(e, "epoch_authenticator")), "%s[%d] epoch %d authenticator", file, ti, ei)
		}
		group_destroy(g)
		ran += 1
	}
	return
}

@(test)
test_passive_client_welcome :: proc(t: ^testing.T) {
	n := run_passive(t, "passive-client-welcome.json")
	testing.expect(t, n == 8)
}

@(test)
test_passive_client_handling_commit :: proc(t: ^testing.T) {
	n := run_passive(t, "passive-client-handling-commit.json")
	testing.expect(t, n == 13)
}

// Full round trip of our own code paths: create, add via external proposal,
// commit + welcome, join, remove, commit with path, both sides agree.
@(test)
test_group_lifecycle :: proc(t: ^testing.T) {
	mk_id :: proc(uid: u64) -> Identity {
		id: Identity
		id.sig_priv, id.sig_pub = generate_signature_key()
		b := make([]byte, 8, context.temp_allocator)
		for i in 0 ..< 8 do b[i] = u8(uid >> (56 - 8 * uint(i)))
		id.credential = Credential{CRED_BASIC, b}
		return id
	}
	ext_priv, ext_pub := generate_signature_key()
	es := []External_Sender{{signature_key = ext_pub[:], credential = Credential{CRED_BASIC, {0}}}}
	exts := []Extension{external_senders_extension(es)}
	gid := []byte{0, 0, 0, 0, 0, 0, 0, 42}

	a := mk_id(1)
	b := mk_id(2)
	c := mk_id(3)
	_, akp, asec := key_package_create(&a, context.temp_allocator)
	_, bkp, bsec := key_package_create(&b, context.temp_allocator)
	_, ckp, csec := key_package_create(&c, context.temp_allocator)

	ga, err := group_create(gid, &a, &akp, &asec, exts)
	testing.expect(t, err == .None)
	defer group_destroy(ga)

	// external add of b and c
	for kp in ([]^Key_Package{&bkp, &ckp}) {
		pm, ok := external_proposal(gid, epoch(ga), 0, Proposal{type = .Add, add = kp^}, ext_priv[:], context.temp_allocator)
		testing.expect(t, ok)
		_, _, perr := group_cache_proposal(ga, pm)
		testing.expectf(t, perr == .None, "cache add: %v", perr)
	}
	res, cerr := group_commit(ga, allocator = context.temp_allocator)
	testing.expectf(t, cerr == .None && res.has_welcome, "commit: %v", cerr)
	if cerr != .None do return
	ga1 := res.group
	defer group_destroy(ga1)
	testing.expect(t, epoch(ga1) == 1)

	gb, jerr := group_join(res.welcome, Join_Params{key_package = &bkp, secrets = &bsec, sig_priv = b.sig_priv})
	testing.expectf(t, jerr == .None, "join b: %v", jerr)
	gc, jerr2 := group_join(res.welcome, Join_Params{key_package = &ckp, secrets = &csec, sig_priv = c.sig_priv})
	testing.expectf(t, jerr2 == .None, "join c: %v", jerr2)
	if jerr != .None || jerr2 != .None do return
	defer group_destroy(gb)
	defer group_destroy(gc)
	aa, ab, ac := epoch_authenticator(ga1), epoch_authenticator(gb), epoch_authenticator(gc)
	testing.expect(t, aa == ab && ab == ac, "authenticators agree after welcome")
	ea, eb: [16]byte
	exporter(ga1, "Discord Secure Frames v0", {1, 0, 0, 0, 0, 0, 0, 0}, ea[:])
	exporter(gb, "Discord Secure Frames v0", {1, 0, 0, 0, 0, 0, 0, 0}, eb[:])
	testing.expect(t, ea == eb, "exporter agrees")

	// remove a (leaf 0); b commits (path required), c processes
	pm, ok := external_proposal(gid, 1, 0, Proposal{type = .Remove, remove = 0}, ext_priv[:], context.temp_allocator)
	testing.expect(t, ok)
	_, _, e1 := group_cache_proposal(gb, pm)
	_, _, e2 := group_cache_proposal(gc, pm)
	testing.expect(t, e1 == .None && e2 == .None)
	res2, cerr2 := group_commit(gb, allocator = context.temp_allocator)
	testing.expectf(t, cerr2 == .None && !res2.has_welcome, "commit remove: %v", cerr2)
	if cerr2 != .None do return
	defer group_destroy(res2.group)
	gc2, perr := group_process_commit(gc, res2.commit)
	testing.expectf(t, perr == .None, "process remove commit: %v", perr)
	if perr != .None do return
	defer group_destroy(gc2)
	x, y := epoch_authenticator(res2.group), epoch_authenticator(gc2)
	testing.expect(t, x == y && epoch(gc2) == 2, "authenticators agree after remove")
	// a sees itself removed
	_, _, e3 := group_cache_proposal(ga1, pm)
	testing.expect(t, e3 == .None)
	gx, perr2 := group_process_commit(ga1, res2.commit)
	testing.expectf(t, perr2 == .State && gx == nil, "removed member gets .State: %v", perr2)

	// empty commit (forced path) from c, b processes
	res3, cerr3 := group_commit(gc2, allocator = context.temp_allocator)
	testing.expect(t, cerr3 == .None)
	if cerr3 != .None do return
	defer group_destroy(res3.group)
	gb3, perr3 := group_process_commit(res2.group, res3.commit)
	testing.expectf(t, perr3 == .None, "process empty commit: %v", perr3)
	if perr3 == .None {
		testing.expect(t, epoch_authenticator(gb3) == epoch_authenticator(res3.group))
		group_destroy(gb3)
	}
}
