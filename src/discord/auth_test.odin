package discord

import "core:crypto"
import "core:crypto/rsa"
import "core:encoding/base64"
import "core:strconv"
import "core:strings"
import "core:testing"
import "fc:etf"

// An RSA-OAEP (SHA-256, MGF1 SHA-256) vector made offline with OpenSSL
// (genpkey 2048, pkeyutl -encrypt rsa_padding_mode:oaep), its public key as
// "openssl pkey -pubout -outform DER" (SPKI) and base64url(SHA-256(SPKI)).
@(private = "file")
OAEP_VECTOR := struct {
	n, d, p, q, dp, dq, iq, ct, spki, fingerprint: string,
} {
	n = "9d7e06dfc46d19545a957fbcf1a6d2e66ee845c4966e1840198274e7fd4a6b3da052526bdb00252c1d65a321595c302ff93bb61e6d266219970d5d4ac9333af3bf58cc7bb6a4e2053180e4d16279462dadf8a8d3e686c7799a3a56fcefeca19bd31e26a23d55076c102eb6e41e5ece57f7c3122d042b8a9257c9598b951d37cf1cdd77181108c29081ba475be412257e65173b7ed23b10d8a1c146c72f376e6cef69e43f39a8681b1f80d4ead685878419e87137d1bfddd054de255cc2dff66b7e4e4a2352b04a0654692b9d228c5ae607f22f604e44717386db406d10c28aea36879602f5a9beec512bbb0f6b94dde377f74c1c9fab30545824bd8c1e3006db",
	d = "0da12e27c8105d047a2bbd4df5127d3bfe007ca68d1238126162c88a99d6b53ddf15b616541c9e1aeeec5b2d7400a616f0c324795b9eda6c8bdb01e63550095bb62fe6cfbf630e40697955d41d13e6693b9e17c0f18eb122aaa093e34dec34f6e452beab2f12f5bd24bab639e5baf4b13e3ae93970c69d366f01ce3865e38d19c253e0dfc81f367c09ef79105f8fac4e3a6c02cb61bafc7b79454dcfbfb5f33ea5fc1873a57ccb1c498ee25a64806bbd4ce98c838efc87c7e6b6844506b487baad4e07297686371c90efe6c65a802879d061cc30cf4cc0e85de02f253fee201409bb2ea2f07d1e414fa09a9aa8d52f603db8d6cb3264e728d453b66620c69719",
	p = "d48b8d9750d0d72cb51a38941b76ac64414413b5b02a05872ab277896a2b4b0f4ecf1173b2fa7c6ce94ea5a9bd1b7a571da1d15bf201cf0c4a1750cce5fa24013edb0c1511deea77a0cb5cca4ddf0e7496376d95a21770c0f58f54a29e8c2ecca2821a4d675564c403f4181c2ec69f91ecc3c30b7e07bb1e97d650a1f3fbe11f",
	q = "bdb10d1226b57e0ae04fd1e20a3be131110d5f35f6c390a944596e86afdca0564e0bdefa8043e1f8f538bbc08e81d3dd615043b336a05e46ee5deb22c8a6c2f058e7cf2d8c0b8a6e9b76576541b4387a9d0878b3fde86a6ea58d980af167d06ce079139e5d79587f82cc61a3fcea09c6792c52037ddcfb69cd47ff9223f8f6c5",
	dp = "4940ab94fa12700685883af5b89d66feca8ba6eb5882b31309c12677a2b2b714d8897f2f4c010e7f0ecdbf44c7db3f87e4bb8f874bda19bcd7903f95ceb12e558b8f3d13c9ebf50d33cac2f92a6b74f4f38cb8e4f84f71d9df07fe1869e25082d0835c834ed8dc78be10137b2b17e3890c7bcfae174a9cd0076ea2ad9e8431eb",
	dq = "4fba0f8d5679a7ad389433d9b6856e63aa101db957aae0ad540de6977368de7707bc938e63c4a4407808cd58e44c8ad89c23192144cf6870959521d3efd3af51477cbea61d1b68a68e6ed1d2bc27dc2924c13fc21ef0c57315e00a4c67244404cedff4aff6079f7b90650890dd271cceaf75424f37625ec51c43ab9627ca6725",
	iq = "1e32f73a93cf199fc426daed8650b9de82188af84bf7843fa238ebea3f4701c2d4f4e25ffbd644753b4cdc41b614713d4c67c7688cb3f9e1a1f94e79278fc1c61132bd1c139b119dfbaae65f853ca0c76f7b11515aa7b73236ac57feeb37dc8cd19f3604cbbd2717ae70e5ca501173ed2e0ff89a62e01eb79cac2f91ef503cb5",
	ct = "4059ac5c18466dc5880c84a3cefea59b096bce9308bb40fe8d9922d12814db0f8d59acb4b2f51ed16d8453241e700ee9ed02c1e3fd7c769f3ccff7ac4413794a444406ec3cd18475dbb6ccff3551492ea40e494c26657930bdfb50116751d636eb0d7ca2f8a22aa9188a70b6db9d56a4bcbea1efea20b78c2e760a891c9553b3225b67b1cbf80a154e63eda583e69b91f9ded4d2f55d4e969bd1e79ca669c1c1932ba504185aeb73926c4e506ae4962e0c73fc826d9ca133d6dba497d80600de12c1672b976cb7b364cf5dce04a83a2ec556c34d0f8e5661d6aab00f62157ee978485a338a7f07f405caa77b627c2a50bf72c5ff0ca128ab88eab99accbf68ac",
	spki = "30820122300d06092a864886f70d01010105000382010f003082010a02820101009d7e06dfc46d19545a957fbcf1a6d2e66ee845c4966e1840198274e7fd4a6b3da052526bdb00252c1d65a321595c302ff93bb61e6d266219970d5d4ac9333af3bf58cc7bb6a4e2053180e4d16279462dadf8a8d3e686c7799a3a56fcefeca19bd31e26a23d55076c102eb6e41e5ece57f7c3122d042b8a9257c9598b951d37cf1cdd77181108c29081ba475be412257e65173b7ed23b10d8a1c146c72f376e6cef69e43f39a8681b1f80d4ead685878419e87137d1bfddd054de255cc2dff66b7e4e4a2352b04a0654692b9d228c5ae607f22f604e44717386db406d10c28aea36879602f5a9beec512bbb0f6b94dde377f74c1c9fab30545824bd8c1e3006db0203010001",
	fingerprint = "vMrsjaKe4q09YKG1f94GTff31h01nToRh_l70CW3rjM",
}

@(private = "file")
OAEP_PLAINTEXT :: "fastcord oaep vector: 1546819257420087346:0:a_1b2c:dingus"

@(private = "file")
unhex :: proc(s: string) -> []byte {
	out := make([]byte, len(s) / 2, context.temp_allocator)
	for i in 0 ..< len(out) {
		v, _ := strconv.parse_u64_of_base(s[2 * i:][:2], 16)
		out[i] = u8(v)
	}
	return out
}

@(test)
test_rsa_oaep_openssl_vector :: proc(t: ^testing.T) {
	v := OAEP_VECTOR
	s: Ra_Session
	e := [3]byte{1, 0, 1}
	ok := rsa.private_key_set_bytes(&s.key, unhex(v.n), e[:], unhex(v.d), unhex(v.p), unhex(v.q), unhex(v.dp), unhex(v.dq), unhex(v.iq))
	testing.expect(t, ok)
	defer rsa.private_key_clear(&s.key)
	ct := base64.encode(unhex(v.ct), allocator = context.temp_allocator)
	pt, dok := ra_decrypt(&s, ct)
	testing.expect(t, dok)
	testing.expect_value(t, string(pt), OAEP_PLAINTEXT)
	// a flipped bit fails the padding check
	bad := unhex(v.ct)
	bad[100] ~= 1
	_, bok := ra_decrypt(&s, base64.encode(bad, allocator = context.temp_allocator))
	testing.expect(t, !bok)
	// SubjectPublicKeyInfo and fingerprint as crypto.subtle / OpenSSL export them
	spki := spki_rsa(unhex(v.n), 65537, context.temp_allocator)
	testing.expect(t, string(spki) == string(unhex(v.spki)))
	digest := sha256_bytes(spki)
	testing.expect_value(t, base64url_nopad(digest[:], context.temp_allocator), v.fingerprint)
}

// the fake server's side: the public key out of the client's init message
@(private = "file")
server_key :: proc(t: ^testing.T, init: string) -> (pk: rsa.Public_Key, ok: bool) {
	v, perr := etf.from_json(init, context.temp_allocator)
	if perr != .None do return
	m := vmap(v)
	testing.expect_value(t, fstr(m, "op"), "init")
	der, err := base64.decode(fstr(m, "encoded_public_key"), allocator = context.temp_allocator)
	if err != nil do return
	// ... BIT STRING { SEQUENCE { INTEGER n (02 82 01 01 00 + 256 bytes), INTEGER e } }
	pat := [5]byte{0x02, 0x82, 0x01, 0x01, 0x00}
	i := strings.index(string(der), string(pat[:]))
	if i < 0 || i + 5 + 256 + 5 > len(der) do return
	n := der[i + 5:][:256]
	e := der[i + 5 + 256 + 2:][:3]
	return pk, rsa.public_key_set_bytes(&pk, n, e)
}

@(private = "file")
seal :: proc(pk: ^rsa.Public_Key, msg: []byte) -> string {
	ct: [256]byte
	_ = rsa.encrypt_oaep(pk, .SHA256, msg, ct[:])
	return base64.encode(ct[:], allocator = context.temp_allocator)
}

// The protocol against a fake server: hello, nonce proof, the fingerprint
// check, the scanned user, the ticket and the token.
@(test)
test_remote_auth_fake_server :: proc(t: ^testing.T) {
	// the OpenSSL vector's key (ra_session_init's keygen takes seconds in a debug build)
	v := OAEP_VECTOR
	s: Ra_Session
	s.allocator = context.allocator
	e := [3]byte{1, 0, 1}
	testing.expect(t, rsa.private_key_set_bytes(&s.key, unhex(v.n), e[:], unhex(v.d), unhex(v.p), unhex(v.q), unhex(v.dp), unhex(v.dq), unhex(v.iq)))
	testing.expect(t, ra_session_derive(&s))
	defer ra_session_destroy(&s)
	testing.expect_value(t, s.fingerprint, v.fingerprint)
	pk, ok := server_key(t, ra_init_message(&s))
	testing.expect(t, ok)
	defer rsa.public_key_clear(&pk)
	// the fingerprint is SHA-256 of the SPKI the server got
	{
		d := sha256_bytes(s.spki)
		testing.expect_value(t, base64url_nopad(d[:], context.temp_allocator), s.fingerprint)
	}
	act, reply := ra_handle(&s, transmute([]byte)string(`{"op":"hello","heartbeat_interval":41250,"timeout_ms":120000}`))
	testing.expect_value(t, act, Ra_Action.Hello)
	testing.expect_value(t, s.heartbeat_interval, 41250)
	testing.expect_value(t, s.timeout_ms, 120000)
	nonce: [32]byte
	crypto.rand_bytes(nonce[:])
	msg := strings.concatenate({`{"op":"nonce_proof","encrypted_nonce":"`, seal(&pk, nonce[:]), `"}`}, context.temp_allocator)
	act, reply = ra_handle(&s, transmute([]byte)msg)
	testing.expect_value(t, act, Ra_Action.Send)
	testing.expect_value(t, reply, strings.concatenate({`{"op":"nonce_proof","nonce":"`, base64url_nopad(nonce[:], context.temp_allocator), `"}`}, context.temp_allocator))
	// a fingerprint that isn't ours restarts
	act, _ = ra_handle(&s, transmute([]byte)string(`{"op":"pending_remote_init","fingerprint":"nope"}`))
	testing.expect_value(t, act, Ra_Action.Fail)
	act, _ = ra_handle(&s, transmute([]byte)strings.concatenate({`{"op":"pending_remote_init","fingerprint":"`, s.fingerprint, `"}`}, context.temp_allocator))
	testing.expect_value(t, act, Ra_Action.Show_Qr)
	testing.expect_value(t, s.step, Ra_Step.Pending_Remote_Init)
	testing.expect_value(t, ra_qr_url(s.fingerprint), strings.concatenate({"https://discord.com/ra/", s.fingerprint}, context.temp_allocator))
	user := "1546819257420087346:0:0a1b2c3d4e5f:dingus battle"
	act, _ = ra_handle(&s, transmute([]byte)strings.concatenate({`{"op":"pending_ticket","encrypted_user_payload":"`, seal(&pk, transmute([]byte)user), `"}`}, context.temp_allocator))
	testing.expect_value(t, act, Ra_Action.Show_User)
	testing.expect_value(t, s.user_id, Snowflake(1546819257420087346))
	testing.expect_value(t, s.discriminator, "0")
	testing.expect_value(t, s.avatar, "0a1b2c3d4e5f")
	testing.expect_value(t, s.username, "dingus battle")
	// "0" is no avatar
	act, _ = ra_handle(&s, transmute([]byte)strings.concatenate({`{"op":"pending_ticket","encrypted_user_payload":"`, seal(&pk, transmute([]byte)string("1:1234:0:x")), `"}`}, context.temp_allocator))
	testing.expect_value(t, act, Ra_Action.Show_User)
	testing.expect_value(t, s.avatar, "")
	act, _ = ra_handle(&s, transmute([]byte)strings.concatenate({`{"op":"pending_ticket","encrypted_user_payload":"`, seal(&pk, transmute([]byte)string("x:1:a:b")), `"}`}, context.temp_allocator))
	testing.expect_value(t, act, Ra_Action.Fail)
	act, _ = ra_handle(&s, transmute([]byte)string(`{"op":"pending_login","ticket":"tkt"}`))
	testing.expect_value(t, act, Ra_Action.Login)
	testing.expect_value(t, s.ticket, "tkt")
	// POST /users/@me/remote-auth/login answers {"encrypted_token"}
	tok, tok_ok := ra_decrypt_token(&s, seal(&pk, transmute([]byte)string("mfa.token-value")), context.temp_allocator)
	testing.expect(t, tok_ok)
	testing.expect_value(t, tok, "mfa.token-value")
	act, _ = ra_handle(&s, transmute([]byte)string(`{"op":"pending_login"}`))
	testing.expect_value(t, act, Ra_Action.Fail)
	act, _ = ra_handle(&s, transmute([]byte)string(`{"op":"cancel"}`))
	testing.expect_value(t, act, Ra_Action.Cancel)
	act, _ = ra_handle(&s, transmute([]byte)string(`{"op":"heartbeat_ack"}`))
	testing.expect_value(t, act, Ra_Action.Heartbeat_Ack)
	act, _ = ra_handle(&s, transmute([]byte)string(`{"op":"something_new"}`))
	testing.expect_value(t, act, Ra_Action.None)
}

@(test)
test_auth_login_value :: proc(t: ^testing.T) {
	c: Client
	testing.expect_value(t, auth_login_value(&c, "dingus@example.com"), "dingus@example.com")
	testing.expect_value(t, auth_login_value(&c, "555 123-4567"), "+1555 123-4567")
	testing.expect_value(t, auth_login_value(&c, "55"), "55")
	c.auth.country_code = "GB"
	testing.expect_value(t, auth_login_value(&c, "(020) 7946"), "+44(020) 7946")
	testing.expect_value(t, auth_dialing_code("AS"), "+1")
	testing.expect_value(t, auth_dialing_code("ZZ"), "+1")
	testing.expect_value(t, url_component("/channels/@me"), "%2Fchannels%2F%40me")
	testing.expect_value(t, fingerprint_id("1546819257420087346.abc_def"), "1546819257420087346")
}

@(test)
test_auth_form_errors :: proc(t: ^testing.T) {
	parse :: proc(s: string) -> etf.Map {
		v, _ := etf.from_json(s, context.temp_allocator)
		return vmap(v)
	}
	ev: Auth_Event
	auth_form_errors(&ev, 400, parse(`{"message":"Invalid Form Body","code":50035,"errors":{"login":{"_errors":[{"code":"INVALID_LOGIN","message":"Login or password is invalid."}]},"password":{"_errors":[{"code":"INVALID_LOGIN","message":"Login or password is invalid."}]}}}`))
	testing.expect_value(t, ev.login_error, "Login or password is invalid.")
	testing.expect_value(t, ev.password_error, "Login or password is invalid.")
	testing.expect(t, !ev.captcha)
	ev = {}
	auth_form_errors(&ev, 400, parse(`{"password":["Password does not match."]}`))
	testing.expect_value(t, ev.password_error, "Password does not match.")
	ev = {}
	auth_form_errors(&ev, 400, parse(`{"captcha_key":["captcha-required"],"captcha_sitekey":"x","captcha_service":"hcaptcha"}`))
	testing.expect(t, ev.captcha)
	ev = {}
	auth_form_errors(&ev, 429, parse(`{"message":"You are being rate limited.","retry_after":3.2,"global":false}`))
	testing.expect_value(t, ev.message, "You are being rate limited.")
}
