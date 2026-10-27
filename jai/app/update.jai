// Build version, set by CI: -define:FASTCORD_VERSION=v0.2.0. "dev" never prompts.
FASTCORD_VERSION :: "dev";
UPDATE_REPO :: "creikey/fastcord";
UPDATE_PAGE :: "https://creikey.com/fastcord";
UPDATE_INTERVAL :: 6 * time.Hour;

Update_State :: struct {
	mu: locks.Mutex;
	latest: string; // newest release tag seen, owned
	available: bool;
	dismissed: bool;
	t: float32;
	thread: *Thread;
}

upd: Update_State;

// Starts a background thread that checks GitHub's latest release now and every few hours.
update_start :: () {
	// FASTCORD_FAKE_UPDATE=v9.9.9 shows the button without the network (headless UI tests).
	{ fake := os.get_env("FASTCORD_FAKE_UPDATE", temp);
	if fake != "" {
		upd.latest = clone(fake);
		upd.available = true;
		return;
	} }
	if FASTCORD_VERSION == "dev" || platform.is_headless() { return; }
	upd.thread = thread.create_and_start(update_loop, *context);
}
#scope_file

update_loop :: () {
	while true {
		{ tag, ok := fetch_latest_tag(UPDATE_REPO);
		if ok {
			locks.lock(*upd.mu);
			delete(upd.latest);
			upd.latest = tag;
			upd.available = version_newer(tag, FASTCORD_VERSION);
			locks.unlock(*upd.mu);
			if upd.available { platform.request_frame(); }
		} }
		time.sleep(UPDATE_INTERVAL);
	}
}
#scope_export

// GET https://api.github.com/repos/<repo>/releases/latest -> tag_name.
fetch_latest_tag :: (repo: string) -> string, bool {
	tag: string;
	ok: bool;
	host :: "api.github.com";
	tcp, derr := netio.dial_tcp(host, 443);
	if derr != .None { return "", false; }
	sess, terr := tls.connect(netio.tcp_stream(tcp), tls.Config.{alpn = string.["http/1.1"], server_name = host});
	if terr != .None {
		netio.close(netio.tcp_stream(tcp));
		return "", false;
	}
	conn: http.H1_Conn;
	http.h1_init(*conn, tls.stream(sess));
	defer http.h1_destroy(*conn);
	req := http.Request.{
		method = "GET",
		scheme = "https",
		authority = host,
		path = strings.concatenate(string.["/repos/", repo, "/releases/latest"], temp),
		headers = http.Header.[.{"User-Agent", #run join("fastcord/", FASTCORD_VERSION)}, .{"Accept", "application/vnd.github+json"}, .{"Connection", "close"}]
	};
	resp, herr := http.h1_round_trip(*conn, req);
	defer http.response_destroy(*resp);
	if herr != .None || resp.status != 200 { return "", false; }
	http.decode_body(*resp);
	v, jerr := json.parse(view(resp.body), allocator = temp);
	if jerr != .None { return "", false; }
	if v.kind != .Map return tag, ok; obj := v.map;
	if get(obj, "tag_name").kind != .String return tag, ok; t := get(obj, "tag_name").s;
	return clone(t), true;
}

// Compares "v1.2.3" style tags numerically; non-numeric parts compare as 0.
version_newer :: (a: string, b: string) -> bool {
	pa := strings.split(strings.trim_prefix(a, "v"), ".", temp);
	pb := strings.split(strings.trim_prefix(b, "v"), ".", temp);
	for i: 0..cast(int)((max(len(pa), len(pb))))-1 {
		x, y := 0, 0;
		if i < len(pa) { x, _ = strconv.parse_int(pa[i]); }
		if i < len(pb) { y, _ = strconv.parse_int(pb[i]); }
		if x != y { return x > y; }
	}
	return false;
}

// Small "Update" pill in the title bar's right corner; opens the download page.
update_button :: () {
	locks.lock(*upd.mu);
	show := upd.available && !upd.dismissed;
	latest := clone(upd.latest, temp);
	locks.unlock(*upd.mu);
	if !show { return; }
	ui.animate(*upd.t, 1, 20);
	b := row("update", .Clickable | .Draw_Background | .Hot_Animation);
	b.semantic_size = .[ui.children(), ui.px(24)];
	b.style.radius = all4(12);
	b.style.bg = T("--status-positive");
	b.style.bg_hot = with_alpha(T("--status-positive"), 0.85);
	b.opacity = upd.t;
	sig := ui.signal(b);
	{ ui.parent(b); defer ui.pop_parent();
		spacer(.X, 8);
		icon("dl", "download", 16, .{1, 1, 1, 1});
		spacer(.X, 4);
		label(strings.concatenate(string.["Update ", latest], temp), .Semibold, 12, .{1, 1, 1, 1}, 16);
		spacer(.X, 10);
	}
	if sig.clicked { open_url(UPDATE_PAGE); }
	if sig.right_clicked { upd.dismissed = true; }
	spacer(.X, 8);
}

