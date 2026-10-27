// Account and profile editing (User Settings > My Account / Profiles), shaped
// like the official client's action creators. Bodies come back through
// feature_take (op .User_Patch / .Profile_Patch) so the UI can show errors:
//
//   PATCH /users/@me          {"global_name": ..}                 (display name)
//   PATCH /users/@me          {"username": .., "password": ..}    (username; needs the password)
//   PATCH /users/%40me/profile {"bio": .., "pronouns": ..}        (Profiles > About Me / Pronouns)
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

note_account :: (acc: *Account_Info, u: etf.Map) {
	if is_null(u) { return; }
	a := context.default_allocator; // process-wide, like `account` itself (stores come and go)
	if vhas(u, "email") {free_str(acc.email, a); acc.email = clone_str(fstr(u, "email"), a);}
	if vhas(u, "phone") {free_str(acc.phone, a); acc.phone = clone_str(fstr(u, "phone"), a);}
	if vhas(u, "verified") { acc.verified = fbool(u, "verified"); }
	if vhas(u, "mfa_enabled") { acc.mfa_enabled = fbool(u, "mfa_enabled"); }
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
		if fsnow(u, "id") == me { note_account(acc, u); }
	}
}

// Tags on .User_Patch results, so the UI knows which form sent it.
User_Patch_Tag :: enum u64 {
	Display_Name :: 1;
	Username :: 2;
	Profile_Name :: 3; // display name saved from the Profiles page
}

// update_global_name: PATCH /users/@me {"global_name": name} ("" clears it: null).
update_global_name :: (c: *Client, name: string, tag := User_Patch_Tag.Display_Name) {
	w: Json;
	json_init(*w);
	json_obj(*w);
	if name == "" { json_knull(*w, "global_name"); } else { json_kstr(*w, "global_name", name); }
	json_obj_end(*w);
	f_submit(c, .{op = .User_Patch, tag = cast(u64)(tag), method = "PATCH", path = "/users/@me", body = json_string(*w)});
}

// update_username: PATCH /users/@me {"username": .., "password": ..}.
update_username :: (c: *Client, username: string, password: string) {
	w: Json;
	json_init(*w);
	json_obj(*w);
	json_kstr(*w, "username", username);
	json_kstr(*w, "password", password);
	json_obj_end(*w);
	f_submit(c, .{op = .User_Patch, tag = cast(u64)(User_Patch_Tag.Username), method = "PATCH", path = "/users/@me", body = json_string(*w)});
}

// update_profile: PATCH /users/%40me/profile {"bio": .., "pronouns": ..} (the
// editor's path is percent-encoded, unlike PATCH /users/@me; fixture settings).
update_profile :: (c: *Client, pronouns: string, bio: string) {
	w: Json;
	json_init(*w);
	json_obj(*w);
	json_kstr(*w, "bio", bio);
	json_kstr(*w, "pronouns", pronouns);
	json_obj_end(*w);
	f_submit(c, .{op = .Profile_Patch, method = "PATCH", path = "/users/%40me/profile", body = json_string(*w)});
}

// apply_account_result applies a successful .User_Patch / .Profile_Patch body to our user
// (USER_UPDATE follows on the gateway too). Returns a new token when the response has one
// (Discord rotates it on username/password changes); "" otherwise.
apply_account_result :: (s: *Store, r: *Feature_Result) -> string {
	new_token: string;
	if !r.ok { return ""; }
	m := vmap(r.body);
	if r.op == {
	case .User_Patch;
		if fsnow(m, "id") == s.me {
			parse_user_into(s, m);
			note_account(*account, m);
		}
		new_token = fstr(m, "token");
	case .Profile_Patch;
		{ u, ok := map_find_ptr(*s.users, s.me);
		if ok {
			a := s.allocator;
			if vhas(m, "bio") {free_str(u.bio, a); u.bio = clone_str(fstr(m, "bio"), a);}
			if vhas(m, "pronouns") {free_str(u.pronouns, a); u.pronouns = clone_str(fstr(m, "pronouns"), a);}
		} }
	}
	s.changed += 1;
	return new_token;
}

// api_error_text: the first field error of a 400 body ({"errors": {"username": {"_errors":
// [{"message": ..}]}}}), else its "message"; "" when there is none.
api_error_text :: (body: V) -> string {
	find :: (v: V) -> string {
		m := vmap(v);
		if is_null(m) { return ""; }
		for e: flist(m, "_errors") {
			{ t := fstr(vmap(e), "message");
			if t != "" { return t; } }
		}
		for p: m {
			{ t := find(p.value);
			if t != "" { return t; } }
		}
		return "";
	}
	m := vmap(body);
	{ t := find(vget(m, "errors"));
	if t != "" { return t; } }
	return fstr(m, "message");
}

// invite_code_from_input: the code from "abc", "discord.gg/abc", "https://discord.com/invite/abc?x=1".
invite_code_from_input :: (s: string) -> string {
	t := strings.trim_space(s);
	for p: (string.["https://", "http://"]) { t = strings.trim_prefix(t, p); }
	for p: (string.["www.", "ptb.", "canary."]) { t = strings.trim_prefix(t, p); }
	for p: (string.["discord.gg/", "discord.com/invite/", "discordapp.com/invite/", "discord.new/"]) {
		if strings.has_prefix(t, p) {
			t = sub_from(t, len(p));
			break;
		}
	}
	{ i := strings.index_any(t, "?#/");
	if i >= 0 { t = sub(t, 0, i); } }
	for ch: t {
		ok := ch >= #char "a" && ch <= #char "z" || ch >= #char "A" && ch <= #char "Z" || ch >= #char "0" && ch <= #char "9" || ch == #char "-" || ch == #char "_";
		if !ok { return ""; }
	}
	return t;
}

