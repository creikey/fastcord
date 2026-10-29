// Account and profile editing (User Settings > My Account / Profiles), shaped
// like the official client's action creators. Bodies come back through
// feature_take (op .User_Patch / .Profile_Patch) so the UI can show errors:
//
//   PATCH /users/@me          {"global_name": ..}                 (display name)
//   PATCH /users/@me          {"username": .., "password": ..}    (username; needs the password)
//   PATCH /users/%40me/profile {"bio": .., "pronouns": ..}        (Profiles > About Me / Pronouns)
//   PATCH /users/@me          {"password": .., "new_password": ..} (Change Password; a new token)
//   POST /users/@me/mfa/totp/enable {"code", "secret"}, POST .../totp/disable (2FA; a new token)
//   POST /users/@me/disable | /users/@me/delete {"password"}       (Account Removal, then logout)
//
// Display name and profile shapes: fixture settings. Username: the web bundle
// (UserSettingsAccountActionCreators.saveAccountChanges; needs the password, not captured).

// Private account fields from READY / USER_UPDATE (only our own user carries them).
Account_Info :: struct {
	email: string;
	phone: string;
	verified: bool;
	mfa_enabled: bool;
}

account: Account_Info;
#scope_file

account_mu: locks.Mutex; // clients write `account` from their own threads (tests run several)

note_account :: (acc: *Account_Info, u: etf.Map) {
	locks.lock(*account_mu);
	defer locks.unlock(*account_mu);
	a := context.default_allocator; // process-wide, like `account` itself (stores come and go)
	if vhas(u, "email") { free_str(acc.email, a); acc.email = clone_str(fstr(u, "email"), a); }
	if vhas(u, "phone") { free_str(acc.phone, a); acc.phone = clone_str(fstr(u, "phone"), a); }
	if vhas(u, "verified") acc.verified = fbool(u, "verified");
	if vhas(u, "mfa_enabled") acc.mfa_enabled = fbool(u, "mfa_enabled");
}
#scope_export

// account_dispatch: called from extras_dispatch after the Store applied `name`.
account_dispatch :: (s: *Store, allocator: Allocator, name: string, data: V) {
	account_apply(*account, s.me, name, data);
}

account_apply :: (acc: *Account_Info, me: Snowflake, name: string, data: V) {
	if name == {
	case "READY"; #through; case "USER_UPDATE";
		d := vmap(data);
		u := ifx name == "READY" then fmap(d, "user") else d;
		if fsnow(u, "id") == me note_account(acc, u);
	}
}

// Tags on .User_Patch results, so the UI knows which form sent it.
User_Patch_Tag :: enum u64 {
	Display_Name :: 1;
	Username :: 2;
	Profile_Name :: 3; // display name saved from the Profiles page
	Password :: 4;
	Totp_Enable :: 5;
	Totp_Disable :: 6;
	Disable_Account :: 7;
	Delete_Account :: 8;
}

// change_password: PATCH /users/@me {"password", "new_password"} (saveAccountChanges).
change_password :: (c: *Client, password: string, new_password: string) {
	w: Json;
	json_init(*w);
	json_obj(*w);
	json_kstr(*w, "password", password);
	json_kstr(*w, "new_password", new_password);
	json_obj_end(*w);
	f_submit(c, .{op = .User_Patch, tag = cast(u64) User_Patch_Tag.Password, method = "PATCH", path = "/users/@me", body = json_string(*w)});
}

// totp_enable: POST /users/@me/mfa/totp/enable {"code", "secret"} (the password comes through the
// MFA check); the reply holds the new token and backup_codes.
totp_enable :: (c: *Client, code: string, secret: string) {
	w: Json;
	json_init(*w);
	json_obj(*w);
	json_kstr(*w, "code", code);
	json_kstr(*w, "secret", secret);
	json_obj_end(*w);
	f_submit(c, .{op = .User_Patch, tag = cast(u64) User_Patch_Tag.Totp_Enable, method = "POST", path = "/users/@me/mfa/totp/enable", body = json_string(*w)});
}

// totp_disable: POST /users/@me/mfa/totp/disable, no body (the MFA check asks for a code).
totp_disable :: (c: *Client) {
	f_submit(c, .{op = .User_Patch, tag = cast(u64) User_Patch_Tag.Totp_Disable, method = "POST", path = "/users/@me/mfa/totp/disable"});
}

// remove_account: POST /users/@me/disable (or /delete) {"password"}; the client logs out after.
remove_account :: (c: *Client, password: string, delete: bool) {
	w: Json;
	json_init(*w);
	json_obj(*w);
	json_kstr(*w, "password", password);
	json_obj_end(*w);
	tag := ifx delete then User_Patch_Tag.Delete_Account else .Disable_Account;
	f_submit(c, .{op = .User_Patch, tag = cast(u64) tag, method = "POST", path = ifx delete then "/users/@me/delete" else "/users/@me/disable", body = json_string(*w)});
}

// totp_secret: a new authenticator secret, 10 random bytes as 16 base32 letters (temp).
totp_secret :: () -> string {
	ALPHABET :: "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
	raw: [10]u8;
	crypto.random_bytes(raw);
	out := alloc_string(16,, temp);
	for i: 0..15 {
		bit := i * 5;
		v := ((cast(u32) raw[bit / 8]) << 8) | (ifx bit / 8 + 1 < 10 then cast(u32) raw[bit / 8 + 1] else 0);
		out[i] = ALPHABET[(v >> (11 - bit % 8)) & 31];
	}
	return out;
}

// update_global_name: PATCH /users/@me {"global_name": name} ("" clears it: null).
update_global_name :: (c: *Client, name: string, tag := User_Patch_Tag.Display_Name) {
	w: Json;
	json_init(*w);
	json_obj(*w);
	if name json_kstr(*w, "global_name", name); else json_knull(*w, "global_name");
	json_obj_end(*w);
	f_submit(c, .{op = .User_Patch, tag = cast(u64) tag, method = "PATCH", path = "/users/@me", body = json_string(*w)});
}

// update_username: PATCH /users/@me {"username": .., "password": ..}.
update_username :: (c: *Client, username: string, password: string) {
	w: Json;
	json_init(*w);
	json_obj(*w);
	json_kstr(*w, "username", username);
	json_kstr(*w, "password", password);
	json_obj_end(*w);
	f_submit(c, .{op = .User_Patch, tag = cast(u64) User_Patch_Tag.Username, method = "PATCH", path = "/users/@me", body = json_string(*w)});
}

// update_profile: PATCH /users/%40me/profile {"bio": .., "pronouns": ..} (the
// editor's path is percent-encoded, unlike PATCH /users/@me; fixture settings), with
// "accent_color" (Banner Color; -1 clears it: null) when it changed (pendingAccentColor).
ACCENT_UNCHANGED :: -2;
update_profile :: (c: *Client, pronouns: string, bio: string, accent: s64 = ACCENT_UNCHANGED) {
	w: Json;
	json_init(*w);
	json_obj(*w);
	json_kstr(*w, "bio", bio);
	json_kstr(*w, "pronouns", pronouns);
	if accent == -1 json_knull(*w, "accent_color");
	else if accent >= 0 json_kint(*w, "accent_color", accent);
	json_obj_end(*w);
	f_submit(c, .{op = .Profile_Patch, method = "PATCH", path = "/users/%40me/profile", body = json_string(*w)});
}

// user_settings_call: a User Settings page's request; the result comes back as .User_Settings with tag.
//   GET /auth/sessions, POST /auth/sessions/logout {"session_id_hashes": [..]}   (Logged-in Devices)
//   GET /users/@me/connections, DELETE /users/@me/connections/{type}/{id},
//   GET /connections/{type}/authorize                                            (Connections)
//   GET /oauth2/tokens, DELETE /oauth2/tokens/{id}                               (Authorized Apps)
user_settings_call :: (c: *Client, tag: u64, method: string, path: string, body := "") {
	f_submit(c, .{op = .User_Settings, tag = tag, method = method, path = path, body = body});
}

// ---- Multi-factor checks (the HTTP layer's MFA_REQUIRED interceptor and openMFAModal) ----
//
// A request answered 401 {"code": 60003, "mfa": {"ticket", "methods": [{"type": "totp" | "sms" |
// "password" | "backup" | "webauthn", ...}]}} is kept by the feature worker. The user proves it
// (POST /mfa/finish {"ticket", "mfa_type", "data"} -> {"token"}) and the request goes again with
// X-Discord-MFA-Authorization: <token>, its result coming back under its own op.

mfa_required :: (r: *Feature_Result) -> bool {
	m := vmap(r.body);
	return r.status == 401 && fint(m, "code") == 60003 && vhas(m, "mfa");
}

mfa_finish :: (c: *Client, ticket: string, mfa_type: string, data: string) {
	w: Json;
	json_init(*w);
	json_obj(*w);
	json_kstr(*w, "ticket", ticket);
	json_kstr(*w, "mfa_type", mfa_type);
	json_kstr(*w, "data", data);
	json_obj_end(*w);
	f_submit(c, .{op = .Mfa_Finish, method = "POST", path = "/mfa/finish", body = json_string(*w), retries = 2});
}

// mfa_retry sends the kept request again with the token /mfa/finish returned; false if none is kept.
mfa_retry :: (c: *Client, token: string) -> bool {
	locks.lock(*fpool.mu);
	if !fpool.has_mfa_job {
		locks.unlock(*fpool.mu);
		return false;
	}
	j := fpool.mfa_job;
	fpool.has_mfa_job = false;
	locks.unlock(*fpool.mu);
	j.mfa_token = token;
	f_submit(c, j);
	j.mfa_token = "";
	f_job_free(*j);
	return true;
}

// apply_account_result applies a successful .User_Patch / .Profile_Patch body to our user
// (USER_UPDATE follows on the gateway too). Returns a new token when the response has one
// (Discord rotates it on username/password changes); "" otherwise.
apply_account_result :: (s: *Store, r: *Feature_Result) -> string {
	if !r.ok return "";
	new_token: string;
	m := vmap(r.body);
	if r.op == {
	case .User_Patch;
		if fsnow(m, "id") == s.me {
			parse_user_into(s, m);
			note_account(*account, m);
		}
		new_token = fstr(m, "token");
		if r.tag == cast(u64) User_Patch_Tag.Totp_Enable || r.tag == cast(u64) User_Patch_Tag.Totp_Disable {
			locks.lock(*account_mu);
			account.mfa_enabled = r.tag == cast(u64) User_Patch_Tag.Totp_Enable;
			locks.unlock(*account_mu);
		}
	case .Profile_Patch; #through;
	case .Banner_Edit;
		u := table_find_pointer(*s.users, s.me);
		if u {
			a := s.allocator;
			if vhas(m, "bio") { free_str(u.bio, a); u.bio = clone_str(fstr(m, "bio"), a); }
			if vhas(m, "pronouns") { free_str(u.pronouns, a); u.pronouns = clone_str(fstr(m, "pronouns"), a); }
			if vhas(m, "banner") { free_str(u.banner, a); u.banner = clone_str(fstr(m, "banner"), a); }
			if vhas(m, "accent_color") {
				ac := vget(m, "accent_color");
				u.has_accent_color = !vis_null(ac);
				u.accent_color = ifx u.has_accent_color then cast(u32) vint(ac) else 0;
			}
		}
	}
	s.changed += 1;
	return new_token;
}

// api_error_text: the first field error of a 400 body ({"errors": {"username": {"_errors":
// [{"message": ..}]}}}), else its "message"; "" when there is none.
api_error_text :: (body: V) -> string {
	find :: (v: V, depth := 0) -> string {
		if depth > 32 return "";
		m := vmap(v);
		for flist(m, "_errors") {
			t := fstr(vmap(it), "message");
			if t return t;
		}
		for m {
			t := find(it.value, depth + 1);
			if t return t;
		}
		return "";
	}
	m := vmap(body);
	t := find(vget(m, "errors"));
	return ifx t then t else fstr(m, "message");
}

// invite_code_from_input: the code from "abc", "discord.gg/abc", "https://discord.com/invite/abc?x=1".
invite_code_from_input :: (s: string) -> string {
	t := trim(s);
	for string.["https://", "http://", "www.", "ptb.", "canary."] if begins_with(t, it) t = advance(t, it.count);
	for string.["discord.gg/", "discord.com/invite/", "discordapp.com/invite/", "discord.new/"] {
		if begins_with(t, it) {
			t = advance(t, it.count);
			break;
		}
	}
	i := find_index_of_any_from_left(t, "?#/");
	if i >= 0 t.count = i;
	for cast([]u8) t if !is_alnum(it) && it != #char "-" return "";
	return t;
}

