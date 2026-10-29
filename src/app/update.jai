// Build version: jai build.jai - release vX.Y.Z passes it as the module parameter VERSION. "dev" never prompts.
FASTCORD_VERSION :: VERSION;
UPDATE_REPO :: "creikey/fastcord";
UPDATE_PAGE :: "https://creikey.com/fastcord";
UPDATE_INTERVAL_MS :: 6 * 60 * 60 * 1000;

Update_State :: struct {
	mu: locks.Mutex;
	latest: string; // newest release tag seen, owned
	notes: string; // its release body (tools/release_notes.py's markdown), owned
	available: bool;
	dismissed: bool;
	t: float32;
	target: string; // what an update replaces (selfupdate.target_of), "" when it can't: the pill opens the page
	install: s32; // atomic: 0 idle, 1 downloading, 2 ready to restart, 3 failed (opens the page), 4 page opened
}

upd: Update_State;

// Starts a background thread that checks GitHub's latest release now and every few hours.
update_start :: () {
	if FASTCORD_VERSION == "dev" || platform.is_headless() return;
	#if OS == .WINDOWS inst.offer = !install_declined && !platform.is_installed();
	upd.target = copy_string(selfupdate.target_of(get_path_of_running_executable()));
	#if OS == .WINDOWS if !platform.is_installed() upd.target = ""; // the zip's copy: the install bar comes first
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
	label(ifx st == 1 then L("Installing…") else ifx st == 3 then L("Fastcord couldn't be installed.") else L("Install Fastcord to open it from the Start menu."), .Medium, 14, WHITE, 18);
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
			label(ifx b == "Install" then L("Install") else L("Not Now"), .Medium, 14, WHITE, 18);
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

// GET https://api.github.com/repos/<repo>/releases/latest -> tag_name and body.
fetch_latest_tag :: (repo: string) -> tag: string, notes: string, ok: bool {
	body, ok := https_get("api.github.com", tprint("/repos/%/releases/latest", repo), 1 << 20, "application/vnd.github+json");
	if !ok return "", "", false;
	v, jerr := etf.from_json(xx body,, temp);
	if jerr != .None || v.kind != .Map return "", "", false;
	t, tok := etf.map_get(v.map, "tag_name");
	if !tok || t.kind != .String || t.s.count > 64 return "", "", false;
	for t.s if !is_alnum(it) && it != #char "." && it != #char "-" return "", "", false; // it goes in download paths
	b, bok := etf.map_get(v.map, "body");
	notes := ifx bok && b.kind == .String then slice(b.s, 0, min(b.s.count, 4096)) else "";
	return copy_string(t.s), copy_string(notes), true;
}

// GET https://<host><path> over HTTP/1.1, following up to 3 redirects to https URLs (a release download
// redirects to GitHub's asset host). The body, at most max bytes, is in temp.
https_get :: (host_in: string, path_in: string, max: int, accept := "*/*") -> []u8, bool {
	host, path := host_in, path_in;
	for 0..3 {
		tcp, derr := netio.dial_tcp(host, 443);
		if derr != .None return .[], false;
		sess, terr := tls.connect(netio.tcp_stream(tcp), tls.Config.{alpn = string.["http/1.1"], server_name = host});
		if terr != .None {
			netio.close(netio.tcp_stream(tcp));
			return .[], false;
		}
		conn: http.H1_Conn;
		http.h1_init(*conn, tls.stream(sess), http.H1_Limits.{max_body = max});
		defer http.h1_destroy(*conn);
		req := http.Request.{method = "GET", scheme = "https", authority = host, path = path,
			headers = http.Header.[.{"User-Agent", #run join("fastcord/", FASTCORD_VERSION)}, .{"Accept", accept}, .{"Connection", "close"}]};
		resp, herr := http.h1_round_trip(*conn, req);
		defer http.response_destroy(*resp);
		if herr != .None return .[], false;
		if resp.status >= 300 && resp.status < 400 {
			loc := http.header_get(resp.headers, "location");
			if !begins_with(loc, "https://") return .[], false;
			rest := advance(loc, 8);
			slash := find_index_from_left(rest, "/");
			if slash <= 0 return .[], false;
			host = copy_string(slice(rest, 0, slash),, temp);
			path = copy_string(advance(rest, slash),, temp);
			continue;
		}
		if resp.status != 200 || http.decode_body(*resp, max) != .None || resp.body.count > max return .[], false;
		return array_copy(resp.body,, temp), true;
	}
	return .[], false;
}

// The install thread (the pill's click): the signed manifest, then the archive it vouches for, then the swap.
update_install :: (_: *void) {
	locks.lock(*upd.mu);
	tag := copy_string(upd.latest,, temp);
	locks.unlock(*upd.mu);
	dir := tprint("/%/releases/download/%/", UPDATE_REPO, tag);
	ok := false;
	manifest, mok := https_get("github.com", join(dir, selfupdate.MANIFEST,, temp), selfupdate.MAX_MANIFEST);
	sig, sok := https_get("github.com", join(dir, selfupdate.SIGNATURE,, temp), 64);
	hash, hok := selfupdate.manifest_hash(xx manifest, sig, tag);
	if !mok || !sok || !hok {
		log_error("update: % has no manifest signed by the release key", tag);
	} else {
		archive, aok := https_get("github.com", join(dir, selfupdate.ASSET,, temp), selfupdate.MAX_ARCHIVE);
		if !aok || !crypto.constant_time_equal(crypto.sha256(archive), hash) log_error("update: % didn't download or doesn't match its manifest", selfupdate.ASSET);
		else if !selfupdate.install(archive, upd.target) log_error("update: couldn't replace %", upd.target);
		else ok = true;
	}
	atomic_store(*upd.install, cast(s32) ifx ok then 2 else 3);
	platform.request_frame();
	reset_temporary_storage();
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

// Small "Update" pill in the title bar's right corner; hovering shows what changed, clicking opens the
// download page.
update_button :: () {
	locks.lock(*upd.mu);
	show := upd.available && !upd.dismissed;
	latest := copy_string(upd.latest,, temp);
	notes := copy_string(upd.notes,, temp);
	locks.unlock(*upd.mu);
	st := atomic_load(*upd.install);
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
		label(ifx st == 1 then L("Updating…") else ifx st == 2 then L("Restart to Update") else tprint(L("Update %"), latest), .Semibold, 12, .{1, 1, 1, 1}, 16);
		spacer(.X, 10);
	}
	if sig.hovering && notes update_notes(notes, b.rect);
	// Installs in place when it can (release builds; see selfupdate), else opens the download page.
	if st == 3 {
		atomic_store(*upd.install, 4);
		open_url(UPDATE_PAGE);
	}
	if sig.clicked && st == 0 && upd.target {
		atomic_store(*upd.install, 1);
		dc.spawn(cast(*void) null, update_install);
	} else if sig.clicked && st == 2 && selfupdate.restart(upd.target) {
		platform.inject_event(.{kind = .Quit});
	} else if sig.clicked && st != 1 {
		open_url(UPDATE_PAGE);
	}
	if sig.right_clicked upd.dismissed = true;
	spacer(.X, 8);
}

#scope_file

// The release body under the pill: "## Area" headings and "- change" lines, at most 14 of them (the
// compare link and anything past that left out).
update_notes :: (notes: string, r: ui.Rect) {
	W :: 360;
	card := ui.box("update_notes", .Draw_Background | .Draw_Border | .Draw_Shadow | .Floating_X | .Floating_Y | .Overlay);
	card.semantic_size = .[ui.px(W), ui.children()];
	p := ui.top_parent();
	card.fixed_pos = .{clamp(r.x1 - W, 8, app.ui.window.x - W - 8) - p.rect.x0, r.y1 + 8 - p.rect.y0};
	card.layout_axis = .Y;
	card.style.bg = T("--background-surface-highest");
	card.style.border_color = T("--border-subtle");
	card.style.border = 1;
	card.style.radius = all4(8);
	card.style.shadow_color = .{0, 0, 0, 0.3};
	card.style.shadow_blur = 12;
	ui.parent(card); defer ui.pop_parent();
	spacer(.Y, 8);
	n := 0;
	for line: split(notes, "\n",, temp) {
		l := trim(line);
		if !l || begins_with(l, "All changes:") continue;
		n += 1;
		if n > 14 break;
		heading := begins_with(l, "#");
		text := ifx heading then trim(trim_left(l, "#")) else ifx begins_with(l, "- ") then join("• ", advance(l, 2),, temp) else l;
		rw := row(tprint("n%", n));
		rw.semantic_size = .[ui.pct(1), ui.children()];
		{ ui.parent(rw); defer ui.pop_parent();
			spacer(.X, 12);
			t := ui.box(tprint("%##t", text), .Draw_Text | .Wrap_Text);
			t.semantic_size = .[ui.fill(), ui.text_size()];
			t.style.font = F(ifx heading then .Semibold else .Normal);
			t.style.font_size = 14;
			t.style.line_height = 18;
			t.style.text_color = T(ifx heading then "--text-strong" else "--text-default");
			spacer(.X, 12);
		}
		spacer(.Y, cast(float32) ifx heading then 2 else 4);
	}
	spacer(.Y, 4);
}

update_loop :: (_: *void) {
	if upd.target selfupdate.delete_path(selfupdate.old_path(upd.target)); // left by an update that wasn't restarted into
	while true {
		tag, notes, ok := fetch_latest_tag(UPDATE_REPO);
		if ok {
			locks.lock(*upd.mu);
			free(upd.latest);
			free(upd.notes);
			upd.latest = tag;
			upd.notes = notes;
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
