// Build version: jai build.jai - release vX.Y.Z passes it as the module parameter VERSION. "dev" never prompts.
FASTCORD_VERSION :: VERSION;
UPDATE_REPO :: "creikey/fastcord";
UPDATE_PAGE :: "https://creikey.com/fastcord";
UPDATE_INTERVAL_MS :: 6 * 60 * 60 * 1000;

Update_State :: struct {
	mu: locks.Mutex;
	latest: string; // newest release tag seen, owned
	available: bool;
	dismissed: bool;
	t: float32;
}

upd: Update_State;

// Starts a background thread that checks GitHub's latest release now and every few hours.
update_start :: () {
	// FASTCORD_FAKE_UPDATE=v9.9.9 shows the button without the network (headless UI tests).
	fake := env_var("FASTCORD_FAKE_UPDATE");
	if fake != "" {
		upd.latest = copy_string(fake);
		upd.available = true;
		return;
	}
	if FASTCORD_VERSION == "dev" || platform.is_headless() return;
	#if OS == .WINDOWS inst.offer = !install_declined && !platform.is_installed();
	dc.spawn(cast(*void) null, update_loop); // runs until the process exits
}

// Windows release builds run from wherever the zip was unpacked: a bar offers the per-user install
// (platform.install) until Not Now. Installed, the new copy starts and this one quits.
install_declined: bool; // settings.json
inst: struct {
	offer: bool;
	state: s32; // atomic: 0 idle, 1 installing, 2 done, 3 failed
};

install_notice :: () {
	if !inst.offer return;
	st := atomic_load(*inst.state);
	#if OS == .WINDOWS if st == 2 {
		inst.offer = false;
		platform.launch_installed();
		platform.inject_event(.{kind = .Quit});
		return;
	}
	WHITE :: ui.Color.{1, 1, 1, 1};
	bar := row("install_notice", .Draw_Background);
	bar.semantic_size = .[ui.pct(1), ui.px(36)];
	bar.style.bg = T("--background-brand");
	ui.parent(bar); defer ui.pop_parent();
	filler(.X);
	label(ifx st == 1 then "Installing…" else ifx st == 3 then "Fastcord couldn't be installed." else "Install Fastcord to open it from the Start menu.", .Medium, 14, WHITE, 18);
	if st == 1 { filler(.X); return; }
	for b: string.["Install", "Not Now"] {
		spacer(.X, 10);
		r := row(b, .Clickable | .Draw_Border | .Draw_Background | .Hot_Animation);
		r.semantic_size = .[ui.children(), ui.px(24)];
		r.style.border = 1;
		r.style.border_color = WHITE;
		r.style.radius = all4(4);
		r.style.bg_hot = with_alpha(WHITE, 0.1);
		{ ui.parent(r); defer ui.pop_parent();
			spacer(.X, 10);
			label(b, .Medium, 14, WHITE, 18);
			spacer(.X, 10);
		}
		if !ui.signal(r).clicked continue;
		if b == "Not Now" { inst.offer = false; install_declined = true; }
		#if OS == .WINDOWS if b == "Install" && !platform.is_headless() {
			atomic_store(*inst.state, 1);
			dc.spawn(cast(*void) null, (_: *void) {
				atomic_store(*inst.state, cast(s32) ifx platform.install(FASTCORD_VERSION) then 2 else 3);
				platform.request_frame();
			});
		}
	}
	filler(.X);
}

// GET https://api.github.com/repos/<repo>/releases/latest -> tag_name.
fetch_latest_tag :: (repo: string) -> string, bool {
	host :: "api.github.com";
	tcp, derr := netio.dial_tcp(host, 443);
	if derr != .None return "", false;
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
		path = tprint("/repos/%/releases/latest", repo),
		headers = http.Header.[.{"User-Agent", #run join("fastcord/", FASTCORD_VERSION)}, .{"Accept", "application/vnd.github+json"}, .{"Connection", "close"}]
	};
	resp, herr := http.h1_round_trip(*conn, req);
	defer http.response_destroy(*resp);
	if herr != .None || resp.status != 200 return "", false;
	http.decode_body(*resp);
	v, jerr := etf.from_json(string.{resp.body.count, resp.body.data},, temp);
	if jerr != .None || v.kind != .Map return "", false;
	t, ok := etf.map_get(v.map, "tag_name");
	if !ok || t.kind != .String return "", false;
	return copy_string(t.s), true;
}

// Compares "v1.2.3" style tags numerically; non-numeric parts compare as 0.
version_newer :: (a: string, b: string) -> bool {
	pa := split(trim_v(a), ".",, temp);
	pb := split(trim_v(b), ".",, temp);
	for i: 0..max(pa.count, pb.count) - 1 {
		x := ifx i < pa.count then string_to_int(pa[i]) else 0;
		y := ifx i < pb.count then string_to_int(pb[i]) else 0;
		if x != y return x > y;
	}
	return false;
}

// Small "Update" pill in the title bar's right corner; opens the download page.
update_button :: () {
	locks.lock(*upd.mu);
	show := upd.available && !upd.dismissed;
	latest := copy_string(upd.latest,, temp);
	locks.unlock(*upd.mu);
	if !show return;
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
		label(tprint("Update %", latest), .Semibold, 12, .{1, 1, 1, 1}, 16);
		spacer(.X, 10);
	}
	if sig.clicked open_url(UPDATE_PAGE);
	if sig.right_clicked upd.dismissed = true;
	spacer(.X, 8);
}

#scope_file

update_loop :: (_: *void) {
	while true {
		tag, ok := fetch_latest_tag(UPDATE_REPO);
		if ok {
			locks.lock(*upd.mu);
			free(upd.latest);
			upd.latest = tag;
			upd.available = version_newer(tag, FASTCORD_VERSION);
			locks.unlock(*upd.mu);
			if upd.available platform.request_frame();
		}
		reset_temporary_storage();
		sleep_milliseconds(UPDATE_INTERVAL_MS);
	}
}

// Odin's strings.trim_prefix(s, "v").
trim_v :: (s: string) -> string { return ifx begins_with(s, "v") then advance(s, 1) else s; }
