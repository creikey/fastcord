package dave

import "core:crypto/aes"
import "core:encoding/hex"
import "core:testing"
import "fc:voice/mls"

@(private = "file")
unhex :: proc(s: string) -> []byte {
	b, _ := hex.decode(transmute([]byte)s, context.temp_allocator)
	return b
}

@(test)
test_uleb :: proc(t: ^testing.T) {
	buf: [10]byte
	for v in ([]u64{0, 1, 127, 128, 300, 16383, 16384, 1 << 31, 0xffff_ffff}) {
		n := uleb_put(buf[:], v)
		testing.expect(t, n == uleb_size(v))
		got, m, ok := uleb_get(buf[:n])
		testing.expect(t, ok && m == n && got == v)
	}
	_, _, ok := uleb_get({0x80, 0x80})
	testing.expect(t, !ok, "unterminated")
}

@(test)
test_displayable_codes :: proc(t: ^testing.T) {
	d: [64]byte
	for i in 0 ..< 64 do d[i] = u8(100 + i)
	c30, ok := displayable_code(d[:], 30, 5, context.temp_allocator)
	testing.expect(t, ok && c30 == "395609108542610941354566097185")
	c45, ok2 := displayable_code(d[:], 45, 5, context.temp_allocator)
	testing.expect(t, ok2 && c45 == "395609108542610941354566097185487100023551760")
	testing.expect(t, format_code("1234567890", 5, context.temp_allocator) == "12345 67890")
	_, bad := displayable_code(d[:10], 30, 5)
	testing.expect(t, !bad)
}

@(test)
test_scrypt_rfc7914 :: proc(t: ^testing.T) {
	out: [64]byte
	scrypt(nil, nil, 16, 1, 1, out[:])
	testing.expect(t, mls.bytes_equal(out[:], unhex("77d6576238657b203b19ca42c18a0497f16b4844e3074ae8dfdffa3fede21442fcd0069ded0948f8326a753a0fc81f17e8d3e0fb2e0d3628cf35e20c38d18906")))
	scrypt(transmute([]byte)string("password"), transmute([]byte)string("NaCl"), 1024, 8, 16, out[:])
	testing.expect(t, mls.bytes_equal(out[:], unhex("fdbabe1c9d3472007856e7190d01e9fe7c6ad7cbc8237830e77376634b3731622eaf30d92e22a3886ff109279d9830dac727afb94a83ee6d8360cbdfa2cc0640")))
}

@(test)
test_pairwise_fingerprint :: proc(t: ^testing.T) {
	ka, kb: [65]byte
	for i in 0 ..< 65 {
		ka[i] = 4
		kb[i] = 5
	}
	fp := pairwise_fingerprint(1, ka[:], 2, kb[:])
	fp2 := pairwise_fingerprint(2, kb[:], 1, ka[:])
	testing.expect(t, fp == fp2, "symmetric")
	testing.expect(t, mls.bytes_equal(fp[:], unhex("916f8300de455ef71c8c895aa2411fb569a4541f55cfbe2767af78436b00d384138b93051f86852651e8bfd12c2a9a98d731faea7bd91a83928e4b3ab3ca03e2")))
	code, ok := verification_code(fp[:], context.temp_allocator)
	testing.expect(t, ok && code == "143349642802495576956579961024728834608636012")
}

@(test)
test_gcm_truncated :: proc(t: ^testing.T) {
	key := unhex("000102030405060708090a0b0c0d0e0f")
	pt := transmute([]byte)string("an opus frame of some length....!")
	ct := make([]byte, len(pt), context.temp_allocator)
	tag: [8]byte
	gcm_seal_truncated(key, 0x01020304, nil, pt, ct, tag[:])
	// matches a full GCM tag prefix with the expanded nonce
	ctx: aes.Context_GCM
	aes.init_gcm(&ctx, key)
	iv := [12]byte{0, 0, 0, 0, 0, 0, 0, 0, 0x04, 0x03, 0x02, 0x01}
	ct2 := make([]byte, len(pt), context.temp_allocator)
	full: [16]byte
	aes.seal_gcm(&ctx, ct2, full[:], iv[:], nil, pt)
	testing.expect(t, mls.bytes_equal(ct, ct2) && mls.bytes_equal(tag[:], full[:8]))
	out := make([]byte, len(pt), context.temp_allocator)
	testing.expect(t, gcm_open_truncated(key, 0x01020304, nil, ct, tag[:], out) && mls.bytes_equal(out, pt))
	ct[3] ~= 1
	testing.expect(t, !gcm_open_truncated(key, 0x01020304, nil, ct, tag[:], out), "tamper detected")
}

@(test)
test_frame_roundtrip :: proc(t: ^testing.T) {
	base := unhex("00112233445566778899aabbccddeeff")
	r1, r2: Ratchet
	ratchet_init(&r1, base)
	ratchet_init(&r2, base)
	defer ratchet_destroy(&r1)
	defer ratchet_destroy(&r2)
	frame := []byte{0x78, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10}
	for nonce in ([]u32{0, 1, 300, 0x01000005}) {
		k, _ := ratchet_get(&r1, nonce >> 24)
		buf: [64]byte
		n := encrypt_opus_frame(k[:], nonce, frame, buf[:])
		testing.expect(t, n == len(frame) + supplemental_size(nonce))
		testing.expect(t, buf[n - 1] == 0xFA && buf[n - 2] == 0xFA && int(buf[n - 3]) == supplemental_size(nonce))
		p, ok := parse_protocol_frame(buf[:n])
		testing.expect(t, ok && p.nonce == nonce && p.n_ranges == 0)
		k2, _ := ratchet_get(&r2, p.nonce >> 24)
		out: [64]byte
		m, dok := decrypt_frame(k2[:], &p, out[:])
		testing.expect(t, dok && mls.bytes_equal(out[:m], frame))
	}
	_, isp := parse_protocol_frame(frame)
	testing.expect(t, !isp, "plain opus is not a protocol frame")
}

@(test)
test_frame_unencrypted_ranges :: proc(t: ^testing.T) {
	// hand-built VP8-style frame: first byte unencrypted, rest encrypted
	key := unhex("0f0e0d0c0b0a09080706050403020100")
	frame := []byte{0x10, 1, 2, 3, 4, 5}
	ct := make([]byte, 5, context.temp_allocator)
	tag: [8]byte
	gcm_seal_truncated(key, 7, frame[:1], frame[1:], ct, tag[:])
	buf := make([dynamic]byte, context.temp_allocator)
	append(&buf, frame[0])
	append(&buf, ..ct)
	append(&buf, ..tag[:])
	append(&buf, 7) // nonce
	append(&buf, 0, 1) // range offset 0 size 1
	append(&buf, u8(8 + 1 + 2 + 1 + 2))
	append(&buf, 0xFA, 0xFA)
	p, ok := parse_protocol_frame(buf[:])
	testing.expect(t, ok && p.n_ranges == 1)
	out: [16]byte
	m, dok := decrypt_frame(key, &p, out[:])
	testing.expect(t, dok && mls.bytes_equal(out[:m], frame))
}

// ---------------------------------------------------------------------------
// Two clients and a scripted voice gateway (external sender) end to end.

@(private = "file")
Fake_Gw :: struct {
	ext_priv: [mls.NSK]byte,
	ext_raw:  []byte,
}

@(private = "file")
gw_init :: proc(gw: ^Fake_Gw) {
	pub: [mls.NPK]byte
	gw.ext_priv, pub = mls.generate_signature_key()
	w := mls.writer_make()
	mls.w_external_sender(&w, mls.External_Sender{signature_key = pub[:], credential = mls.Credential{mls.CRED_BASIC, {0}}})
	gw.ext_raw = w.buf[:]
}

@(private = "file")
take :: proc(s: ^Session, op: int) -> (o: Outgoing, ok: bool) {
	outs := session_take_outgoing(s, context.temp_allocator)
	for x in outs {
		if x.op == op && !ok {
			o = x
			ok = true
			continue
		}
		delete(x.data)
	}
	return
}

@(private = "file")
proposals_payload :: proc(msgs: [][]byte) -> []byte {
	w := mls.writer_make()
	mls.w_u8(&w, 0)
	p := mls.w_begin(&w)
	for m in msgs do mls.w_raw(&w, m)
	mls.w_end(&w, p)
	return w.buf[:]
}

@(private = "file")
add_for :: proc(gw: ^Fake_Gw, g: ^mls.Group, kp_msg: []byte) -> []byte {
	r := mls.reader_make(kp_msg)
	kp := mls.r_key_package(&r, context.temp_allocator)
	assert(mls.r_done(&r))
	msg, ok := mls.external_proposal(mls.group_id(g), mls.epoch(g), 0, mls.Proposal{type = .Add, add = kp}, gw.ext_priv[:], context.temp_allocator)
	assert(ok)
	return msg
}

@(test)
test_session_end_to_end :: proc(t: ^testing.T) {
	gw: Fake_Gw
	gw_init(&gw)
	CH :: u64(1564227670806364345)
	UA :: u64(1546819257420087346)
	UB :: u64(1090123456789012345)
	a, b: Session
	session_init(&a, UA, CH)
	session_init(&b, UB, CH)
	defer session_destroy(&a)
	defer session_destroy(&b)

	on_clients_connect(&a, {UB})
	on_clients_connect(&b, {UA})
	on_select_protocol_ack(&a, 1)
	on_select_protocol_ack(&b, 1)
	akp, ok1 := take(&a, OP_MLS_KEY_PACKAGE)
	bkp, ok2 := take(&b, OP_MLS_KEY_PACKAGE)
	testing.expect(t, ok1 && ok2, "key packages sent")
	defer delete(akp.data)
	defer delete(bkp.data)
	// key package shape as the official client: mls10, suite 2, identity = BE user id
	testing.expect(t, akp.data[0] == 0 && akp.data[1] == 1 && akp.data[2] == 0 && akp.data[3] == 2 && akp.data[4] == 0x40 && akp.data[5] == 0x41)

	on_external_sender(&a, gw.ext_raw)
	on_external_sender(&b, gw.ext_raw)
	testing.expect(t, a.pending != nil && b.pending != nil, "pending groups")

	// gateway broadcasts add proposals to each pending member
	on_proposals(&a, proposals_payload({add_for(&gw, a.pending, bkp.data)}))
	on_proposals(&b, proposals_payload({add_for(&gw, b.pending, akp.data)}))
	acw, ok3 := take(&a, OP_MLS_COMMIT_WELCOME)
	bcw, ok4 := take(&b, OP_MLS_COMMIT_WELCOME)
	testing.expect(t, ok3 && ok4, "both commit")
	defer delete(acw.data)
	defer delete(bcw.data)

	// a wins: split its op 28 payload into commit and welcome
	r := mls.reader_make(acw.data)
	commit := mls.r_mls_message_raw(&r)
	welcome := acw.data[len(commit):]
	testing.expect(t, commit != nil && len(welcome) > 0)

	TID :: 7
	on_announce_commit(&a, TID, commit)
	on_announce_commit(&b, TID, commit) // b is unestablished: ignored
	on_welcome(&b, TID, welcome)
	ra, ok5 := take(&a, OP_READY_FOR_TRANSITION)
	rb, ok6 := take(&b, OP_READY_FOR_TRANSITION)
	testing.expect(t, ok5 && ok6 && ra.transition_id == TID && rb.transition_id == TID, "ready for transition")

	// before execute: still passthrough
	frame := []byte{0xfc, 0xff, 0xfe, 9, 8, 7}
	buf: [64]byte
	n := session_encrypt(&a, frame, buf[:])
	testing.expect(t, n == len(frame), "passthrough before execute")

	on_execute_transition(&a, TID)
	on_execute_transition(&b, TID)
	sa := session_status(&a, context.temp_allocator)
	sb := session_status(&b, context.temp_allocator)
	testing.expect(t, sa.e2ee_active && sb.e2ee_active, "e2ee on")
	testing.expect(t, len(sa.privacy_code) == 30 && sa.privacy_code == sb.privacy_code, "privacy codes match")

	for i in 0 ..< 3 {
		n = session_encrypt(&a, frame, buf[:])
		testing.expect(t, n > len(frame))
		out: [64]byte
		m, res := session_decrypt(&b, UA, buf[:n], out[:])
		testing.expectf(t, res == .Ok && mls.bytes_equal(out[:m], frame), "b decrypts a's frame %d", i)
		_, res2 := session_decrypt(&b, UA, buf[:n], out[:])
		testing.expect(t, res2 == .Failed, "replay rejected")
	}
	// plain frames now rejected (passthrough window only during upgrade)
	b.passthrough_until = 0
	out2: [64]byte
	_, res3 := session_decrypt(&b, UA, frame, out2[:])
	testing.expect(t, res3 == .Failed, "plain frame rejected after upgrade")
	_, res4 := session_decrypt(&b, UA, {0xF8, 0xFF, 0xFE}, out2[:])
	testing.expect(t, res4 == .Passthrough, "silence always passes")

	// verification codes agree
	ca, cok := session_verification_code(&a, UB, context.temp_allocator)
	cb, cok2 := session_verification_code(&b, UA, context.temp_allocator)
	testing.expect(t, cok && cok2 && ca == cb && len(ca) == 45, "verification codes match")

	// remove b: a commits (with path), new epoch, a's old frames still decrypt for 10s
	rm, rok := mls.external_proposal(mls.group_id(a.current), mls.epoch(a.current), 0, mls.Proposal{type = .Remove, remove = 1}, gw.ext_priv[:], context.temp_allocator)
	testing.expect(t, rok)
	on_proposals(&a, proposals_payload({rm}))
	acw2, ok7 := take(&a, OP_MLS_COMMIT_WELCOME)
	testing.expect(t, ok7, "remove commit")
	defer delete(acw2.data)
	on_announce_commit(&a, 8, acw2.data)
	_, ok8 := take(&a, OP_READY_FOR_TRANSITION)
	testing.expect(t, ok8 && mls.epoch(a.current) == 2)
	on_execute_transition(&a, 8)
	sa2 := session_status(&a, context.temp_allocator)
	testing.expect(t, sa2.epoch == 2 && sa2.privacy_code != sa.privacy_code)

	// a frame from the new epoch is undecryptable for the removed member
	n = session_encrypt(&a, frame, buf[:])
	out3: [64]byte
	_, res5 := session_decrypt(&b, UA, buf[:n], out3[:])
	testing.expect(t, res5 == .Failed, "removed member cannot decrypt")
}

@(test)
test_session_downgrade_refused :: proc(t: ^testing.T) {
	s: Session
	session_init(&s, 1, 2)
	defer session_destroy(&s)
	on_select_protocol_ack(&s, 1)
	on_prepare_transition(&s, 5, 0)
	testing.expect(t, session_close_request(&s) == .Downgrade_Refused)
}
