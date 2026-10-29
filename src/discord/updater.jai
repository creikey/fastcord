// ---- the native updater ----
// The official client's updater (updater.node: Rust, reqwest + hyper 1 + native-tls) asks updates.discord.com for
// the manifest at launch, retries a failed check on the splash's Backoff(1 s, 30 s) and checks again every
// hour. When the manifest offers a newer host it downloads that host's package (the delta from the host it
// runs, else the full one), checks its SHA-256 and installs it at the next start; fastcord fetches the same
// package, hashes and discards it, and runs the offered host from its next launch (identity_learn_offered).
// Its connections are the OS's TLS (src/ostls) and HTTP/1.1 as hyper writes it: the request line, then
// accept, user-agent, accept-encoding and host, lower case, in that order (captured: Windows 1.0.9266 and
// macOS 0.0.419 against a local NEW_UPDATE_ENDPOINT).

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
	fetched: string; // the host version whose package came through this launch
	idle: [..]Updater_Conn;
}

Updater_Conn :: struct {
	host: string;
	conn: *http.H1_Conn;
	used_ms: s64;
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
	i := 0;
	while i < u.idle.count {
		it := u.idle[i];
		if now_ms() - it.used_ms >= UPDATER_IDLE_MS {
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

updater_request :: (host: string, path: string) -> http.Request {
	return .{method = "GET", scheme = "https", authority = host, path = path, headers = array_copy(http.Header.[.{"accept", "*/*"}, .{"user-agent", "Discord-Updater/1"}, .{"accept-encoding", "gzip"}, .{"host", host}],, temp)};
}

// updater_check: the manifest, then the offered host's package if it is newer than the one fastcord reports.
// False when the check should be retried: no answer, a status other than 200, or a package that did not come
// through intact. A 200 whose body is not a usable manifest counts as done (guess).
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
	locks.unlock(*c.id.mu);
	pkg, newer := updater_package(vmap(v), running);
	if !newer || pkg.version == c.updater.fetched return true;
	// a failed download is tried once more at once ("Host download failed (attempt 1), retrying")
	for 1..2 if updater_download(c, pkg) {
		free(c.updater.fetched,, context.default_allocator);
		c.updater.fetched = copy_string(pkg.version,, context.default_allocator);
		return true;
	}
	return false;
}

Updater_Package :: struct {
	version: string;
	host: string;
	path: string;
	sha256: [32]u8;
}

// updater_package: the package the updater installs to go from running to the manifest's host: the delta
// whose host_version is running, else the full package; newer is false when the manifest's host is not newer
// or names no package fastcord would fetch (an https URL on the default port, a 64-hex-digit hash).
updater_package :: (m: etf.Map, running: string) -> Updater_Package, newer: bool {
	pkg: Updater_Package;
	full := vmap(vget(m, "full"));
	ok, offered := updater_version(vget(full, "host_version"));
	have, current := host_version_parse(running);
	if !ok || !have || !version_less(current, offered) return pkg, false;
	pkg.version = tprint("%.%.%", offered[0], offered[1], offered[2]);
	src := full;
	deltas := flist(m, "deltas");
	if deltas.count > 64 return pkg, false;
	for deltas {
		dok, from := updater_version(vget(vmap(it), "host_version"));
		if dok && !version_less(from, current) && !version_less(current, from) src = vmap(it);
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
		return true;
	}
	resp, err := updater_get(c, pkg.host, pkg.path, UPDATER_PACKAGE_MAX, .{*ph, take});
	defer http.response_destroy(*resp);
	got := crypto.sha256_final(*ph.h);
	return err == .None && resp.status == 200 && memcmp(got.data, pkg.sha256.data, 32) == 0;
}

// updater_get: one request on a kept connection to host when there is one (hyper's pool), else a new one; a
// kept connection the server closed meanwhile is retried once on a new one. With Config.round_tripper (tests)
// the request goes there instead.
updater_get :: (c: *Client, host: string, path: string, max_body: int, sink := http.Body_Sink.{}) -> http.Response, http.Error {
	req := updater_request(host, path);
	if c.transport.override.round_trip {
		resp, err := c.transport.override.round_trip(c.transport.override.data, host, req);
		if err == .None && sink.take && !sink.take(sink.data, resp.body) err = .Closed;
		return resp, err;
	}
	u := *c.updater;
	for attempt: 0..1 {
		conn: *http.H1_Conn;
		for u.idle if it.host == host {
			conn = it.conn;
			free(it.host,, context.default_allocator);
			array_unordered_remove_by_index(*u.idle, it_index);
			break;
		}
		kept := conn != null;
		if !conn {
			tcp, derr := netio.dial_tcp(host, 443, public_only = true);
			if derr != .None return .{}, .Io;
			s, terr := ostls.connect(netio.tcp_stream(tcp), host);
			if terr != .None return .{}, .Io;
			conn = New(http.H1_Conn,, context.default_allocator);
			http.h1_init(conn, s,, context.default_allocator);
		}
		conn.limits.max_body = max_body;
		resp, err := http.h1_round_trip(conn, req, sink);
		if err == .None && conn.reusable {
			array_add(*u.idle, .{copy_string(host,, context.default_allocator), conn, now_ms()},, context.default_allocator);
		} else {
			http.h1_destroy(conn);
			free(conn,, context.default_allocator);
		}
		if kept && err != .None && resp.status == 0 continue;
		return resp, err;
	}
	return .{}, .Io;
}

updater_drop :: (k: Updater_Conn) {
	http.h1_destroy(k.conn);
	free(k.conn,, context.default_allocator);
	free(k.host,, context.default_allocator);
}
