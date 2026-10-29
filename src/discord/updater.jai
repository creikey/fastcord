// ---- the native updater ----
// The official client's updater (updater.node: Rust, reqwest + hyper 1 + native-tls) asks updates.discord.com for
// the manifest at launch, retries a failed check on the splash's Backoff(1 s, 30 s) and checks again every
// hour. When the manifest offers a newer host it downloads that host's package and every installed module's
// (deltas from what it runs, else full ones), four at a time, checks their SHA-256 and installs them at the
// next start; fastcord fetches the same packages, hashes and discards them, and runs the offered host from its
// next launch (identity_learn_offered).
// Its connections are the OS's TLS (src/ostls) and HTTP/1.1 as hyper writes it: the request line, then
// accept, user-agent, accept-encoding and host, lower case, in that order (captured: Windows 1.0.9266 and
// macOS 0.0.419 against a local NEW_UPDATE_ENDPOINT, Linux 1.0.167 too). The Linux updater's rustls offers h2,
// and over HTTP/2 the same headers go as hyper's h2 client sends them (no host; http.H2_Config.hyper).

UPDATER_HOST :: "updates.discord.com";
UPDATER_CHECK_MS :: 60 * 60 * 1000;
UPDATER_BACKOFF_MIN_MS :: 1000; // DESKTOP_TTI_UPDATE_BACKOFF_MAX_MS's default is the max
UPDATER_BACKOFF_MAX_MS :: 30_000;
UPDATER_IDLE_MS :: 90_000; // hyper-util's pool idle timeout (reqwest's default): then the socket is dropped
UPDATER_MANIFEST_MAX :: 1 << 20; // ~120 KB today
UPDATER_PACKAGE_MAX :: 1 << 30;

Updater :: struct {
	scheduled: bool; // the check job exists (UI thread)
	// The rest belongs to the check job, which one worker runs at a time.
	backoff_ms: s64; // Backoff's current delay, 0 = not failing
	next_check_ms: s64;
	fetched: string; // the host version whose packages came through this launch
	modules: [..]Updater_Module; // installed module versions, from a manifest for the running host
	mu: locks.Mutex; // idle, shared by the parallel downloads
	idle: [..]Updater_Conn; // HTTP/1.1 connections at rest, and HTTP/2 ones whether in use or not
}

Updater_Conn :: struct {
	host: string;
	conn: *http.H1_Conn;
	h2: *http.H2_Conn; // instead of conn
	used_ms: s64;      // HTTP/2: when a request last took it (hyper-util's pool resets idle_at then)
}

// updater_schedule: the launch check (schedule_app_load), once per client.
updater_schedule :: (c: *Client) {
	if c.updater.scheduled return;
	c.updater.scheduled = true;
	j := job_new(.Web, .Startup);
	j.host_manifest = true;
	j.method = "GET";
	j.host = UPDATER_HOST;
	j.not_before = c.launch_ms;
	job_submit(c, j);
}

// updater_run (worker): the check when it is due, then the job sleeps until the next check or until a kept
// connection has idled out.
updater_run :: (c: *Client, j: *Job) {
	u := *c.updater;
	now := now_ms();
	if now >= u.next_check_ms {
		if updater_check(c) {
			u.backoff_ms = 0;
			u.next_check_ms = now + UPDATER_CHECK_MS;
		} else {
			u.backoff_ms = updater_backoff(u.backoff_ms, random_get_zero_to_one());
			u.next_check_ms = now_ms() + u.backoff_ms;
		}
	}
	j.not_before = u.next_check_ms;
	locks.lock(*u.mu);
	defer locks.unlock(*u.mu);
	i := 0;
	while i < u.idle.count {
		it := u.idle[i];
		if now_ms() - it.used_ms >= UPDATER_IDLE_MS || (it.h2 && !http.h2_can_open(it.h2)) {
			updater_drop(it);
			array_unordered_remove_by_index(*u.idle, i);
			continue;
		}
		j.not_before = min(j.not_before, it.used_ms + UPDATER_IDLE_MS);
		i += 1;
	}
	j.requeue = true;
}

// updater_backoff: Backoff.fail() with jitter: the delay grows by up to twice itself, capped.
updater_backoff :: (current: s64, r: float) -> s64 {
	cur := ifx current > 0 then current else UPDATER_BACKOFF_MIN_MS;
	return min(cur + cast(s64) (2 * cur * r), UPDATER_BACKOFF_MAX_MS);
}

updater_destroy :: (c: *Client) {
	for c.updater.idle updater_drop(it);
	array_free(c.updater.idle);
	for c.updater.modules free(it.name,, context.default_allocator);
	array_free(c.updater.modules);
	free(c.updater.fetched,, context.default_allocator);
}

// updater_manifest_path: install_id, channel, platform, arch, platform_version (the OS's version as the
// updater reads it: macOS's product version, Windows' major.minor.build) and client_version (the native build
// of the host it runs).
updater_manifest_path :: (c: *Client) -> string {
	locks.lock(*c.id.mu);
	p := c.id.platform;
	path := tprint("/distributions/app/manifests/latest?install_id=%&channel=%&platform=%&arch=%&platform_version=%&client_version=%",
		c.id.updater_install_id, p.release_channel, updater_platform(p), p.app_arch, ifx p.os_product_version then p.os_product_version else p.os_version, p.native_build_number);
	locks.unlock(*c.id.mu);
	return path;
}

// updater_request: hyper-util adds host only for HTTP/1 (Client::send_request); h2 has :authority.
updater_request :: (host: string, path: string, h2 := false) -> http.Request {
	headers := array_copy(http.Header.[.{"accept", "*/*"}, .{"user-agent", "Discord-Updater/1"}, .{"accept-encoding", "gzip"}, .{"host", host}],, temp);
	if h2 headers.count -= 1;
	return .{method = "GET", scheme = "https", authority = host, path = path, headers = headers};
}

// updater_check: the manifest, then the packages of the offered host if it is newer than the one fastcord
// reports. False when the check should be retried: no answer, a status other than 200, or a package that did
// not come through intact. A 200 whose body is not a usable manifest counts as done (guess).
updater_check :: (c: *Client) -> bool {
	resp, err := updater_get(c, UPDATER_HOST, updater_manifest_path(c), UPDATER_MANIFEST_MAX);
	defer http.response_destroy(*resp);
	if err != .None || resp.status != 200 return false;
	if http.decode_body(*resp, UPDATER_MANIFEST_MAX) != .None return true;
	host_manifest_loaded(c, resp.body);
	v, jerr := etf.from_json(cast(string) resp.body,, temp);
	if jerr != .None return true;
	locks.lock(*c.id.mu);
	running := copy_string(c.id.platform.client_version,, temp);
	os := c.id.platform.os; // static
	locks.unlock(*c.id.mu);
	u := *c.updater;
	version, pkgs := updater_packages(vmap(v), running, u.modules, os);
	if !version {
		updater_learn_modules(u, vmap(v), running);
		return true;
	}
	if version == u.fetched return true;
	if !updater_download_all(c, pkgs) return false;
	free(u.fetched,, context.default_allocator);
	u.fetched = copy_string(version,, context.default_allocator);
	return true;
}

// updater_on_demand: the modules the desktop core installs at every launch on top of the manifest's
// required_modules (its InstallModule commands in the updater log). A macOS install then has 15: every one
// the manifest lists but discord_ndi and discord_sysimg (the test profile's installer.db). A Windows install
// has 18 (1.0.9266's installer.db, and getModuleVersions()): no webauthn, but clips, hook, media and both
// overlays. A Linux install (1.0.167 in WSL, logged out) adds discord_game_utils, krisp, rpc and zstd; the
// cloudsync, dispatch and modules macOS installs after login are assumed there too (guess).
UPDATER_ON_DEMAND_MAC :: string.["discord_webauthn", "discord_krisp", "discord_game_utils", "discord_cloudsync", "discord_rpc", "discord_dispatch", "discord_modules", "discord_zstd"];
UPDATER_ON_DEMAND_WINDOWS :: string.["discord_clips", "discord_cloudsync", "discord_desktop_overlay", "discord_dispatch", "discord_game_utils", "discord_hook", "discord_krisp", "discord_media", "discord_modules", "discord_overlay2", "discord_rpc", "discord_zstd"];
UPDATER_ON_DEMAND_LINUX :: string.["discord_cloudsync", "discord_dispatch", "discord_game_utils", "discord_krisp", "discord_modules", "discord_rpc", "discord_zstd"];
updater_on_demand :: (os: string) -> []string {
	if os == "Windows" return UPDATER_ON_DEMAND_WINDOWS;
	if os == "Linux" return UPDATER_ON_DEMAND_LINUX;
	return UPDATER_ON_DEMAND_MAC;
}
UPDATER_PARALLEL :: 4; // downloads at once, each on its own HTTP/1.1 connection (captured), or sharing one h2
UPDATER_MAX_MODULES :: 128;

Updater_Package :: struct {
	host: string;
	path: string;
	sha256: [32]u8;
}

Updater_Module :: struct {
	name: string;
	version: s64;
}

// updater_packages: what the updater downloads to go from running to the manifest's host, when that is newer
// (version "" otherwise): the host's package first, then each installed module's in a random order (the
// updater walks a Rust HashMap). Each is the delta from the running host (for a module, from the module version
// installed, else the newest such delta), else the full package. A package fastcord would not fetch (not an
// https URL on the default port, no 64-hex-digit hash) drops the host update, or skips that module.
updater_packages :: (m: etf.Map, running: string, installed: []Updater_Module, os := "") -> version: string, []Updater_Package {
	pkgs: [..]Updater_Package;
	pkgs.allocator = temp;
	full := vmap(vget(m, "full"));
	ok, offered := updater_version(vget(full, "host_version"));
	have, current := host_version_parse(running);
	if !ok || !have || !version_less(current, offered) return "", pkgs;
	host, hok := updater_pick(full, flist(m, "deltas"), current, -1);
	if !hok return "", pkgs;
	array_add(*pkgs, host);
	required := flist(m, "required_modules");
	modules := vmap(vget(m, "modules"));
	if modules.count > UPDATER_MAX_MODULES || required.count > UPDATER_MAX_MODULES return "", pkgs;
	for mod: modules {
		if mod.key.kind != .String continue;
		name := mod.key.s;
		wanted := array_find(updater_on_demand(os), name);
		for required if it.kind == .String && it.s == name wanted = true;
		if !wanted continue;
		from := -1;
		for installed if it.name == name from = it.version;
		pkg, pok := updater_pick(vmap(vget(vmap(mod.value), "full")), flist(vmap(mod.value), "deltas"), current, from);
		if pok array_add(*pkgs, pkg);
	}
	for < i: 2..pkgs.count - 1 {
		k := 1 + cast(int) (random_get_zero_to_one_open() * i);
		pkgs[i], pkgs[k] = pkgs[k], pkgs[i];
	}
	return tprint("%.%.%", offered[0], offered[1], offered[2]), pkgs;
}

// updater_pick: the delta from host current (and from module version from, when >= 0), else full.
updater_pick :: (full: etf.Map, deltas: []V, current: [3]s64, from: s64) -> Updater_Package, bool {
	pkg: Updater_Package;
	if deltas.count > 64 return pkg, false;
	src := full;
	best := -1;
	for deltas {
		d := vmap(it);
		dok, h := updater_version(vget(d, "host_version"));
		if !dok || version_less(h, current) || version_less(current, h) continue;
		mv := vget(d, "module_version");
		n := ifx mv.kind == .Int then mv.i else 0;
		if (from >= 0 && n != from) || n <= best continue;
		src, best = d, n;
	}
	url := vget(src, "url");
	hash := vget(src, "package_sha256");
	if url.kind != .String || hash.kind != .String || hash.s.count != 64 return pkg, false;
	for 0..31 {
		hi, lo := hex_digit(hash.s[2 * it]), hex_digit(hash.s[2 * it + 1]);
		if hi < 0 || lo < 0 return pkg, false;
		pkg.sha256[it] = cast(u8) (hi * 16 + lo);
	}
	pkg.host, pkg.path = https_url_parts(url.s);
	return pkg, pkg.host != "";
}

// updater_learn_modules: a manifest for the host fastcord runs lists the module versions an up-to-date install
// of it has, the ones its module deltas start from at the next update.
updater_learn_modules :: (u: *Updater, m: etf.Map, running: string) {
	ok, h := updater_version(vget(vmap(vget(m, "full")), "host_version"));
	have, current := host_version_parse(running);
	modules := vmap(vget(m, "modules"));
	if !ok || !have || version_less(h, current) || version_less(current, h) || modules.count > UPDATER_MAX_MODULES return;
	for u.modules free(it.name,, context.default_allocator);
	array_reset(*u.modules);
	for modules {
		v := vget(vmap(vget(vmap(it.value), "full")), "module_version");
		if it.key.kind != .String || v.kind != .Int || it.key.s.count > 64 continue;
		array_add(*u.modules, .{copy_string(it.key.s,, context.default_allocator), v.i},, context.default_allocator);
	}
}

// updater_download_all: UPDATER_PARALLEL packages at a time, each tried once more at once when it fails ("Host
// download failed (attempt 1), retrying"); false when one never came through.
updater_download_all :: (c: *Client, pkgs: []Updater_Package) -> bool {
	Work :: struct { c: *Client; pkgs: []Updater_Package; mu: locks.Mutex; next: int; failed: bool; }
	w := Work.{c = c, pkgs = pkgs};
	run :: (w: *Work) {
		while true {
			locks.lock(*w.mu);
			i := w.next;
			w.next += 1;
			locks.unlock(*w.mu);
			if i >= w.pkgs.count break;
			if updater_download(w.c, w.pkgs[i]) || updater_download(w.c, w.pkgs[i]) continue;
			locks.lock(*w.mu);
			w.failed = true;
			locks.unlock(*w.mu);
		}
	}
	threads: [UPDATER_PARALLEL - 1]*Thread;
	for * threads it.* = spawn(*w, run);
	run(*w);
	for threads locks.join(it);
	return !w.failed;
}

updater_version :: (v: V) -> bool, [3]s64 {
	out: [3]s64;
	if v.kind != .List || v.list.count != 3 return false, out;
	for v.list {
		if it.kind != .Int || it.i < 0 || it.i > 999_999 return false, out;
		out[it_index] = it.i;
	}
	return true, out;
}

version_less :: (a: [3]s64, b: [3]s64) -> bool {
	for 0..2 if a[it] != b[it] return a[it] < b[it];
	return false;
}

// https_url_parts: host and path of "https://host/path" (no port, user or fragment, at most 2048 bytes, a host
// of letters, digits, '-' and '.'); "" when it is anything else.
https_url_parts :: (url: string) -> host: string, path: string {
	PREFIX :: "https://";
	if url.count > 2048 || !begins_with(url, PREFIX) return "", "";
	rest := advance(url, PREFIX.count);
	slash := find_index_from_left(rest, #char "/");
	if slash <= 0 || slash > 253 return "", "";
	host := slice(rest, 0, slash);
	path := advance(rest, slash);
	for cast([]u8) host if !(is_alnum(it) || it == #char "-" || it == #char ".") return "", "";
	for cast([]u8) path if it <= 32 || it >= 127 || it == #char "#" return "", "";
	return host, path;
}

Package_Hash :: struct {
	h: crypto.Sha256;
	bytes: int;
}

// updater_download: the package through a hash, never kept.
updater_download :: (c: *Client, pkg: Updater_Package) -> bool {
	ph: Package_Hash;
	crypto.sha256_init(*ph.h);
	take :: (data: *void, piece: []u8) -> bool {
		ph := cast(*Package_Hash) data;
		ph.bytes += piece.count;
		crypto.sha256_update(*ph.h, piece);
		return ph.bytes <= UPDATER_PACKAGE_MAX;
	}
	resp, err := updater_get(c, pkg.host, pkg.path, UPDATER_PACKAGE_MAX, .{*ph, take});
	defer http.response_destroy(*resp);
	got := crypto.sha256_final(*ph.h);
	return err == .None && resp.status == 200 && memcmp(got.data, pkg.sha256.data, 32) == 0;
}

// updater_get: one request on a kept connection to host when there is one (hyper's pool), else a new one; a
// kept connection the server closed meanwhile is retried once on a new one. With Config.round_tripper (tests)
// the request goes there instead. An HTTP/2 connection is shared by the requests to its host. Requests that
// dialled at once each finish their handshake (hyper-util's Ver::Auto connects race the pool's checkout); the
// first to pick h2 is pooled and carries them all, and each later one, found redundant when it is pooled
// (PoolInner::put), sends its preface and is closed again at once.
updater_get :: (c: *Client, host: string, path: string, max_body: int, sink := http.Body_Sink.{}) -> http.Response, http.Error {
	if c.transport.override.round_trip {
		req := updater_request(host, path);
		resp, err := c.transport.override.round_trip(c.transport.override.data, host, req);
		if err == .None && sink.take && !sink.take(sink.data, resp.body) err = .Closed;
		return resp, err;
	}
	u := *c.updater;
	for attempt: 0..1 {
		locks.lock(*u.mu);
		conn, h2 := updater_take(u, host);
		locks.unlock(*u.mu);
		kept := conn || h2;
		if !kept {
			tcp, derr := netio.dial_tcp(host, 443, public_only = true);
			if derr != .None return .{}, .Io;
			s, terr, alpn_h2 := ostls.connect(netio.tcp_stream(tcp), host);
			if terr != .None return .{}, .Io;
			if alpn_h2 {
				fresh, herr := http.h2_connect(s, .{max_response_body = UPDATER_MANIFEST_MAX, hyper = true},, context.default_allocator);
				if herr != .None { netio.close(s); return .{}, .Io; }
				locks.lock(*u.mu);
				_, h2 = updater_take(u, host, h2_only = true);
				if !h2 array_add(*u.idle, .{copy_string(host,, context.default_allocator), null, fresh, now_ms()},, context.default_allocator);
				locks.unlock(*u.mu);
				if h2 http.h2_close(fresh);
				else h2 = fresh;
			} else {
				conn = New(http.H1_Conn,, context.default_allocator);
				http.h1_init(conn, s,, context.default_allocator);
			}
		}
		if h2 {
			req := updater_request(host, path, h2 = true);
			req.sink = sink;
			resp, err := http.h2_request(h2, req); // the connection limits a body sink doesn't take
			if kept && err != .None && resp.status == 0 continue;
			return resp, err;
		}
		conn.limits.max_body = max_body;
		resp, err := http.h1_round_trip(conn, updater_request(host, path), sink);
		if err == .None && conn.reusable {
			locks.lock(*u.mu);
			array_add(*u.idle, .{copy_string(host,, context.default_allocator), conn, null, now_ms()},, context.default_allocator);
			locks.unlock(*u.mu);
		} else {
			http.h1_destroy(conn);
			free(conn,, context.default_allocator);
		}
		if kept && err != .None && resp.status == 0 continue;
		return resp, err;
	}
	return .{}, .Io;
}

// updater_take (u.mu held): host's HTTP/2 connection that can still open streams (it stays pooled), else an
// HTTP/1.1 one at rest (taken out).
updater_take :: (u: *Updater, host: string, h2_only := false) -> *http.H1_Conn, *http.H2_Conn {
	for * u.idle if it.host == host && it.h2 && http.h2_can_open(it.h2) {
		it.used_ms = now_ms();
		return null, it.h2;
	}
	if !h2_only for u.idle if it.host == host && it.conn {
		conn := it.conn;
		free(it.host,, context.default_allocator);
		array_unordered_remove_by_index(*u.idle, it_index);
		return conn, null;
	}
	return null, null;
}

updater_drop :: (k: Updater_Conn) {
	if k.h2 http.h2_close(k.h2);
	else {
		http.h1_destroy(k.conn);
		free(k.conn,, context.default_allocator);
	}
	free(k.host,, context.default_allocator);
}
