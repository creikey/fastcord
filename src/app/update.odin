package app

import "core:encoding/json"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "fc:http"
import "fc:netio"
import "fc:platform"
import "fc:tls"
import "fc:ui"

// Build version, set by CI: -define:FASTCORD_VERSION=v0.2.0. "dev" never prompts.
FASTCORD_VERSION :: #config(FASTCORD_VERSION, "dev")
UPDATE_REPO :: "creikey/fastcord"
UPDATE_PAGE :: "https://creikey.com/fastcord"
UPDATE_INTERVAL :: 6 * time.Hour

Update_State :: struct {
	mu:        sync.Mutex,
	latest:    string, // newest release tag seen, owned
	available: bool,
	dismissed: bool,
	t:         f32,
	thread:    ^thread.Thread,
}

upd: Update_State

// Starts a background thread that checks GitHub's latest release now and every few hours.
update_start :: proc() {
	if FASTCORD_VERSION == "dev" || platform.is_headless() do return
	upd.thread = thread.create_and_start(update_loop, context)
}

@(private = "file")
update_loop :: proc() {
	for {
		if tag, ok := fetch_latest_tag(); ok {
			sync.mutex_lock(&upd.mu)
			delete(upd.latest)
			upd.latest = tag
			upd.available = version_newer(tag, FASTCORD_VERSION)
			sync.mutex_unlock(&upd.mu)
			if upd.available do platform.request_frame()
		}
		time.sleep(UPDATE_INTERVAL)
	}
}

// GET https://api.github.com/repos/<repo>/releases/latest -> tag_name.
@(private = "file")
fetch_latest_tag :: proc() -> (tag: string, ok: bool) {
	host :: "api.github.com"
	tcp, derr := netio.dial_tcp(host, 443)
	if derr != .None do return "", false
	sess, terr := tls.connect(netio.tcp_stream(tcp), tls.Config{alpn = {"http/1.1"}, server_name = host})
	if terr != .None {
		netio.close(netio.tcp_stream(tcp))
		return "", false
	}
	conn: http.H1_Conn
	http.h1_init(&conn, tls.stream(sess))
	defer http.h1_destroy(&conn)
	req := http.Request {
		method    = "GET",
		scheme    = "https",
		authority = host,
		path      = "/repos/" + UPDATE_REPO + "/releases/latest",
		headers   = {{"User-Agent", "fastcord/" + FASTCORD_VERSION}, {"Accept", "application/vnd.github+json"}, {"Connection", "close"}},
	}
	resp, herr := http.h1_round_trip(&conn, req)
	if herr != .None || resp.status != 200 do return "", false
	http.decode_body(&resp)
	v, jerr := json.parse(resp.body[:], allocator = context.temp_allocator)
	if jerr != nil do return "", false
	obj := v.(json.Object) or_return
	t := obj["tag_name"].(json.String) or_return
	return strings.clone(t), true
}

// Compares "v1.2.3" style tags numerically; non-numeric parts compare as 0.
version_newer :: proc(a, b: string) -> bool {
	pa := strings.split(strings.trim_prefix(a, "v"), ".", context.temp_allocator)
	pb := strings.split(strings.trim_prefix(b, "v"), ".", context.temp_allocator)
	for i in 0 ..< max(len(pa), len(pb)) {
		x, y := 0, 0
		if i < len(pa) do x, _ = strconv.parse_int(pa[i])
		if i < len(pb) do y, _ = strconv.parse_int(pb[i])
		if x != y do return x > y
	}
	return false
}

// Small "Update" pill in the title bar's right corner; opens the download page.
update_button :: proc() {
	sync.mutex_lock(&upd.mu)
	show := upd.available && !upd.dismissed
	latest := strings.clone(upd.latest, context.temp_allocator)
	sync.mutex_unlock(&upd.mu)
	if !show do return
	ui.animate(&upd.t, 1, 20)
	b := row("update", {.Clickable, .Draw_Background, .Hot_Animation})
	b.semantic_size = {.X = ui.children(), .Y = ui.px(24)}
	b.style.radius = 12
	b.style.bg = T("--status-positive")
	b.style.bg_hot = with_alpha(T("--status-positive"), 0.85)
	b.opacity = upd.t
	sig := ui.signal(b)
	if ui.parent(b) {
		spacer(.X, 8)
		icon("dl", "download", 16, {1, 1, 1, 1})
		spacer(.X, 4)
		label(strings.concatenate({"Update ", latest}, context.temp_allocator), .Semibold, 12, {1, 1, 1, 1}, 16)
		spacer(.X, 10)
	}
	if sig.clicked do platform.open_url(UPDATE_PAGE)
	if sig.right_clicked do upd.dismissed = true
	spacer(.X, 8)
}
