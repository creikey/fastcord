// The host's side of a self-hosted server: jai build.jai - run src/tests/serve_host.jai, then build/serve_host.
// The file lock, schema migrations, quotas, the owner-only Host routes (storage, files, limits, backups and
// restore, sessions, log) and cleanup. Writes only under build/serve_host_test.
#import "Basic";
#import "File";
#import "File_Utilities";
#import "String";
#import "Base64";
etf :: #import "etf";
http :: #import "http";
keys :: #import "keys";
netio :: #import "netio";
serve :: #import "serve";
sqlite :: #import "sqlite";
tls :: #import "tls";
#if OS == .WINDOWS msvcprt :: #library,system,no_dll,link_always "msvcprt";

DIR :: "build/serve_host_test";

main :: () {
	failed := 0;
	check :: (ok: bool, what: string) #expand {
		if !ok { print("FAIL: %\n", what); `failed += 1; }
	}
	delete_directory(DIR);
	make_directory_if_it_does_not_exist(DIR, recursive = true);
	path := tprint("%/server.db", DIR);

	// Migrations: a file from before numbered schemas is backed up, then brought up to date; a newer one is refused.
	s, ok, err := serve.open(path);
	check(ok, tprint("open: %", err));
	if !ok exit(1);
	serve.stop(s);
	{
		db := sqlite.open(path);
		check(sqlite.exec(db, "ALTER TABLE messages DROP COLUMN stickers; PRAGMA user_version = 0;"), "make an old file");
		sqlite.close(db);
	}
	s, ok, err = serve.open(path);
	check(ok, tprint("an old file opens: %", err));
	if !ok exit(1);
	serve.stop(s);
	{
		db := sqlite.open(path);
		st := sqlite.prepare(db, "SELECT (SELECT count(*) FROM pragma_table_info('messages') WHERE name = 'stickers'), (SELECT user_version FROM pragma_user_version);");
		sqlite.step(st);
		check(sqlite.col_int(st, 0) == 1 && sqlite.col_int(st, 1) == serve.SCHEMA_VERSION, "the old file gains the column and the version");
		sqlite.finalize(st);
		sqlite.exec(db, "PRAGMA user_version = 99;");
		sqlite.close(db);
	}
	backups := file_list(tprint("%/server-backups", DIR));
	check(backups.count == 1 && contains(backups[0], "-pre-v"), tprint("the migration backed the file up first: %", backups));
	s, ok, err = serve.open(path);
	check(!ok && contains(err, "newer fastcord"), tprint("a newer file is refused: %", err));
	{
		db := sqlite.open(path);
		sqlite.exec(db, tprint("PRAGMA user_version = %;", serve.SCHEMA_VERSION));
		sqlite.close(db);
	}

	s, ok, err = serve.open(path);
	check(ok, tprint("reopen: %", err));
	if !ok exit(1);
	_, ok, err = serve.open(path);
	check(!ok && err == "this server is already running", tprint("a second open of the same file is refused: %", err));
	check(serve.listen(s, 0), "listen");
	port, id := s.listener.port, serve.id_hex(s,, context.default_allocator);

	login :: (code: string, k: keys.Keypair, name: string) -> string #expand {
		inv, _ := serve.parse_invite(serve.invite_url(`s, "127.0.0.1", `port, code));
		return serve.member_login(inv, k, name);
	}
	member_key := keys.generate("Member");
	owner := login(serve.owner_invite(s), keys.generate("Owner"), "Owner");
	member := login(serve.first_invite(s), member_key, "Member");
	check(owner != "" && member != "", "both join");
	rest :: (method: string, path: string, body: string, token: string) -> int, string #expand {
		tcp, derr := netio.dial_tcp("127.0.0.1", `port);
		if derr != .None return -1, "";
		session := tls.connect(netio.tcp_stream(tcp), .{alpn = .[serve.ALPN], server_name = `id, pin = `s.pin});
		if !session return -1, "";
		defer tls.close(session);
		h: http.H1_Conn;
		http.h1_init(*h, tls.stream(session));
		defer http.h1_destroy(*h, false);
		req := http.Request.{method = method, path = path, authority = `id, body = cast([]u8) body,
			headers = .[.{"authorization", token}, .{"Content-Type", "application/json"}, .{"Content-Length", tprint("%", body.count)}]};
		resp, rerr := http.h1_round_trip(*h, req);
		if rerr != .None return -2, "";
		return resp.status, copy_string(cast(string) resp.body,, temp);
	}
	field :: (v: etf.Value, key: string) -> etf.Value { if v.kind != .Map return .{}; f := etf.map_get(v.map, key); return f; }
	HOST :: "/api/v9/fc/host";

	status, body := rest("GET", HOST, "", member);
	check(status == 403, tprint("a member can't open the host pages: %", status));
	status, body = rest("GET", HOST, "", owner);
	info, _ := etf.from_json(body);
	check(status == 200 && field(field(info, "limits"), "max_upload_mb").i == 10 && field(field(info, "storage"), "attachments").kind == .Int && field(info, "file_bytes").i > 0 && field(info, "disk_free_bytes").i > 0,
		tprint("the owner reads Server info, Storage and Limits: % %", status, body));

	status, body = rest("PATCH", HOST, "{\"member_quota_mb\": -1}", owner);
	check(status == 400, tprint("a limit out of range is refused: %", status));
	status, body = rest("PATCH", HOST, "{\"address\": \"example.org:80\"}", owner);
	check(status == 400, tprint("an address with a port is refused: %", status));
	status, body = rest("PATCH", HOST, "{\"member_quota_mb\": 1, \"address\": \"chat.example.org\", \"public_port\": 443}", owner);
	check(status == 204, tprint("the owner sets limits and the address: % %", status, body));
	host, invite_port := serve.invite_address(s);
	check(host == "chat.example.org" && invite_port == 443, tprint("invites carry the public address: %:%", host, invite_port));

	status, body = rest("POST", tprint("/api/v9/guilds/%/channels", s.guild), "{\"name\": \"files\"}", owner);
	made, _ := etf.from_json(body);
	channel := field(made, "id").s;
	check(status == 201 && channel != "", tprint("a channel: % %", status, body));
	uploads := tprint("/api/v9/channels/%/attachments", channel);
	slot :: (size: int) -> int #expand {
		st, _ := rest("POST", uploads, tprint("{\"files\": [{\"id\": \"0\", \"filename\": \"big.bin\", \"file_size\": %}]}", size), `member);
		return st;
	}
	check(slot(600_000) == 200, "an upload under the member's quota");
	status, body = rest("POST", uploads, "{\"files\": [{\"id\": \"0\", \"filename\": \"big.bin\", \"file_size\": 600000}]}", member);
	check(status == 413 && contains(body, "40005"), tprint("past the member's quota, 40005: % %", status, body));
	rest("PATCH", HOST, "{\"member_quota_mb\": 0, \"max_upload_mb\": 1}", owner);
	check(slot(2 << 20) == 413, "past the owner's max upload size");

	// A file posted, listed with its uploader, then deleted by the owner: its message had nothing else, so it goes too.
	messages := tprint("/api/v9/channels/%/messages", channel);
	png, _ := base64_decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==",, temp);
	status, body = rest("POST", uploads, tprint("{\"files\": [{\"id\": \"0\", \"filename\": \"dot.png\", \"file_size\": %}]}", png.count), member);
	up, _ := etf.from_json(body);
	list := field(up, "attachments");
	if list.kind == .List && list.list.count {
		url, name := field(list.list[0], "upload_url").s, field(list.list[0], "upload_filename").s;
		rest("PUT", slice(url, find_index_from_left(url, "/upload/"), url.count), png, "");
		status, body = rest("POST", messages, tprint("{\"attachments\": [{\"id\": \"0\", \"filename\": \"dot.png\", \"uploaded_filename\": \"%\"}]}", name), member);
		check(status == 200, tprint("a message with a file: % %", status, body));
	}
	status, body = rest("GET", tprint("%/attachments", HOST), "", owner);
	files, _ := etf.from_json(body);
	check(status == 200 && files.kind == .List && files.list.count == 1 && field(files.list[0], "uploader_name").s == "Member" && field(files.list[0], "channel_name").s == "files",
		tprint("the owner lists files: % %", status, body));
	member_id := "";
	if files.kind == .List && files.list.count {
		member_id = field(files.list[0], "uploader_id").s;
		status, body = rest("POST", tprint("%/attachments/delete", HOST), tprint("{\"ids\": [\"%\"]}", field(files.list[0], "id").s), owner);
		check(status == 200 && contains(body, tprint("\"freed_bytes\":%", png.count)), tprint("the owner deletes a file: % %", status, body));
		status, body = rest("GET", messages, "", owner);
		check(status == 200 && body == "[]", tprint("its empty message went with it: %", body));
	}

	// Back up, change something, restore: the change is gone, and everyone's still signed in.
	status, body = rest("POST", tprint("%/backups", HOST), "", owner);
	snaps, _ := etf.from_json(body);
	got := field(snaps, "backups");
	check(status == 200 && got.kind == .List && got.list.count >= 2, tprint("Back Up Now: % %", status, body));
	newest := ifx got.kind == .List && got.list.count then field(got.list[0], "name").s else "";
	rest("POST", messages, "{\"content\": \"after the backup\"}", member);
	status, body = rest("POST", tprint("%/backups/../server.db/restore", HOST), "", owner);
	check(status == 400, tprint("a restore takes only a backup's name: %", status));
	status, body = rest("POST", tprint("%/backups/%/restore", HOST, newest), "", owner);
	check(status == 204, tprint("restore: % %", status, body));
	status, body = rest("GET", messages, "", member);
	check(status == 200 && !contains(body, "after the backup"), tprint("the restored server has no later message, and the session still works: % %", status, body));
	check(serve.member_login(serve.parse_invite(serve.invite_url(s, "127.0.0.1", port, serve.first_invite(s))), member_key, "") != "", "a member signs in by key after a restore");

	// Cleanup: with a day of retention, messages two days old go.
	rest("POST", messages, "{\"content\": \"old news\"}", member);
	rest("PATCH", HOST, "{\"retention_days\": 1}", owner);
	s.clock_offset_ms = 2 * 86400 * 1000;
	status, body = rest("POST", tprint("%/cleanup", HOST), "", owner);
	check(status == 200, tprint("cleanup: % %", status, body));
	status, body = rest("GET", messages, "", member);
	check(status == 200 && !contains(body, "old news"), tprint("messages past retention are deleted: %", body));
	s.clock_offset_ms = 0;

	status, body = rest("GET", tprint("%/sessions", HOST), "", owner);
	check(status == 200 && body[0] == #char "[", tprint("sessions: % %", status, body));
	status, body = rest("GET", tprint("%/log", HOST), "", owner);
	check(status == 200 && contains(body, "Restored"), tprint("the log tail: % %", status, body));
	status, body = rest("DELETE", tprint("%/sessions/%", HOST, member_id), "", owner);
	check(status == 204, tprint("end a member's sessions: % %", status, body));
	status, body = rest("GET", messages, "", member);
	check(status == 401, tprint("their token no longer works: %", status));

	serve.stop(s);
	if failed { print("serve_host: % failed\n", failed); exit(1); }
	print("serve_host: ok\n");
}
