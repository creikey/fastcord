// Telemetry of the login page and of logging out (traffic/account_edits.jsonl,
// windows logout and login_submit; property order as captured).

// trackNetworkAction: {status_code, error_code?, error_message?, url, request_method, ...properties}.
analytics_network_action :: (c: *Client, event: string, status: int, body: etf.Map, url: string, method: string, extra_key := "", extra_value := "") {
	w := aw_begin();
	json_kint(*w, "status_code", cast(s64)(status));
	if status < 200 || status >= 300 {
		{ code, ok := vget(body, "code").i, vget(body, "code").kind == .Int;
		if ok { json_kint(*w, "error_code", code); } }
		{ m := fstr(body, "message");
		if m != "" { json_kstr(*w, "error_message", m); } }
	}
	json_kstr(*w, "url", url);
	json_kstr(*w, "request_method", method);
	if extra_key != "" { json_kstr(*w, extra_key, extra_value); }
	aw_track(c, event, *w);
}

// login_viewed: the login page (not an invite's) mounted, logged out.
analytics_login_viewed :: (c: *Client) {
	w := aw_begin();
	json_knull(*w, "login_source");
	json_kbool(*w, "authenticated", false);
	json_kstr(*w, "location", "Non-Invite Login Page");
	aw_track(c, "login_viewed", *w);
}

// multi_account_account_remove: "Remove account" in the account switcher's Manage Accounts modal.
analytics_multi_account_remove :: (c: *Client) {
	w := aw_begin();
	json_kstr(*w, "location_section", "Manage Accounts Modal");
	aw_track(c, "multi_account_account_remove", *w);
}

// hotspot_hidden: HotspotActionCreators.hideHotspot; VOICE_PANEL_INTRODUCTION
// is hidden on every VOICE_CHANNEL_SELECT without a channel (a logout included).
analytics_hotspot_hidden :: (c: *Client, location: string) {
	w := aw_begin();
	json_kstr(*w, "hotspot_location", location);
	aw_track(c, "hotspot_hidden", *w);
}
#scope_module

// The fingerprint's id part (before the first '.').
fingerprint_id :: (fp: string) -> string {
	{ i := strings.index_byte(fp, #char ".");
	if i >= 0 { return sub(fp, 0, i); } }
	return fp;
}
#scope_export

analytics_fingerprint_changed :: (c: *Client, fp: string) {
	w := aw_begin();
	json_knull(*w, "old_fingerprint");
	json_kstr(*w, "new_fingerprint", fingerprint_id(fp));
	aw_track(c, "user_fingerprint_changed", *w);
}

analytics_external_fingerprint_dropped :: (c: *Client, kept: string, dropped: string) {
	w := aw_begin();
	json_kstr(*w, "fingerprint", fingerprint_id(kept));
	json_kstr(*w, "dropped_fingerprint", fingerprint_id(dropped));
	aw_track(c, "external_fingerprint_dropped", *w);
}

// login_successful after a QR code login (login_instance_id is the key's fingerprint, as the client passes it).
analytics_login_successful_qr :: (c: *Client, fingerprint: string) {
	w := aw_begin();
	json_kstr(*w, "source", "QR Code Login");
	json_knull(*w, "login_source");
	json_knull(*w, "gift_code_sku_id");
	json_kbool(*w, "is_new_user", false);
	json_kstr(*w, "login_method", "remote_auth");
	if fingerprint != "" { json_kstr(*w, "login_instance_id", fingerprint); } else { json_knull(*w, "login_instance_id"); }
	aw_track(c, "login_successful", *w);
}

// network_action_user_survey_fetch: the Friends page's survey load.
analytics_survey_fetch :: (c: *Client, status: int, body: etf.Map) {
	w := aw_begin();
	json_kint(*w, "status_code", cast(s64)(status));
	if status < 200 || status >= 300 {
		{ code, ok := vget(body, "code").i, vget(body, "code").kind == .Int;
		if ok { json_kint(*w, "error_code", code); } }
		{ m := fstr(body, "message");
		if m != "" { json_kstr(*w, "error_message", m); } }
	}
	json_kstr(*w, "url", "/users/@me/survey");
	json_kstr(*w, "request_method", "get");
	json_kstr(*w, "location", "impression_friends");
	json_kstr(*w, "location_page", "impression_friends");
	aw_track(c, "network_action_user_survey_fetch", *w);
}

