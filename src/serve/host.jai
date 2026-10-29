// The host's side of a self-hosted server: the schema's version and its migrations, the log beside the file,
// rolling backups and restore, storage limits and cleanup, and the owner-only routes the app's Host pages call
// (/api/v9/fc/host/...). Only the owner reaches them; nothing here is Discord's.

#import "File";
#import "File_Utilities";
#import "Sort";

// Bump SCHEMA_VERSION whenever a table or a column is added, and add the column to COLUMNS: a file at an
// older version is backed up, then migrated in one transaction; a file at a newer one is refused.
SCHEMA_VERSION :: 1;

Column :: struct { table: string; def: string; }
// Columns added after their table was first shipped, for files made before them. New files get them from
// the CREATE TABLEs too.
COLUMNS :: Column.[
	.{"users", "left INTEGER NOT NULL DEFAULT 0"},
	.{"users", "banned INTEGER NOT NULL DEFAULT 0"},
	.{"users", "ban_reason TEXT"},
	.{"users", "timeout_until INTEGER"},
	.{"users", "joined_name TEXT"},
	.{"users", "avatar TEXT"},
	.{"users", "avatar_type TEXT"},
	.{"users", "avatar_data BLOB"},
	.{"messages", "reply INTEGER"},
	.{"messages", "everyone INTEGER NOT NULL DEFAULT 0"},
	.{"messages", "pinned_at INTEGER"},
	.{"messages", "type INTEGER NOT NULL DEFAULT 0"},
	.{"messages", "flags INTEGER NOT NULL DEFAULT 0"},
	.{"channels", "topic TEXT NOT NULL DEFAULT ''"},
	.{"events", "channel INTEGER"},
	.{"channels", "type INTEGER NOT NULL DEFAULT 0"},
	.{"channels", "parent INTEGER"},
	.{"channels", "owner INTEGER"},
	.{"channels", "slowmode INTEGER NOT NULL DEFAULT 0"},
	.{"channels", "nsfw INTEGER NOT NULL DEFAULT 0"},
	.{"channels", "archived INTEGER NOT NULL DEFAULT 0"},
	.{"channels", "locked INTEGER NOT NULL DEFAULT 0"},
	.{"channels", "archive_after INTEGER NOT NULL DEFAULT 4320"},
	.{"channels", "archived_at INTEGER"},
	.{"channels", "bitrate INTEGER NOT NULL DEFAULT 64000"},
	.{"channels", "user_limit INTEGER NOT NULL DEFAULT 0"},
	.{"invites", "owner INTEGER NOT NULL DEFAULT 0"},
	.{"invites", "inviter INTEGER"},
	.{"invites", "channel INTEGER"},
	.{"invites", "max_age INTEGER NOT NULL DEFAULT 0"},
	.{"invites", "expires INTEGER NOT NULL DEFAULT 0"},
	.{"messages", "nonce TEXT"},
	.{"messages", "webhook INTEGER NOT NULL DEFAULT 0"},
	.{"messages", "username TEXT"},
	.{"messages", "snapshot TEXT"},
	.{"messages", "stickers TEXT"},
	.{"channels", "tags TEXT"},
	.{"embeds", "rich TEXT"},
	.{"dm_messages", "edited INTEGER"},
];

Host :: struct {
	path: string;          // The server file, as given.
	version := "dev";      // fastcord's, for Server info; the app sets it.
	started: Apollo_Time;  // Wall clock, at open.
	log_mu: locks.Mutex;   // A leaf lock: the log file's appends.
	maint_mu: locks.Mutex; // Guards maint_stop.
	maint_wake: locks.Cond;
	maint_stop: bool;
	maint_thread: *Thread;
	deleted: bool; // Atomic: the owner deleted the server; its file is in the trash, and whoever runs it stops.
}

TRASH_DAYS :: 30;

// trash_dir: deleted servers' files, beside the server's, kept TRASH_DAYS.
trash_dir :: (file: string) -> string { return tprint("%fastcord-trash", path_strip_filename(file)); }

// finish_delete is what runs the server does once the owner deleted it (host.deleted): the server stopped,
// its file and journal go (a copy is in the trash), and so does its service, so nothing makes a new empty
// server at the same path.
finish_delete :: (file: string) {
	path := copy_string(file,, temp);
	for string.["", "-wal", "-shm"] file_delete(tprint("%1%2", path, it));
	file_log(path, "Deleted by its owner; its file is in % for % days", trash_dir(path), TRASH_DAYS);
	install_service(path, 0, uninstall = true);
}

LOG_MAX :: 1 << 20; // Past this, the log moves to <file>.log.1 and starts again.

// host_log appends a line to <file>.log, which a service's owner reads instead of a console.
host_log :: (s: *Server, format: string, args: ..Any) {
	locks.guard(*s.host.log_mu);
	file_log(s.host.path, format, ..args);
}

// file_log is host_log before the server is open (or when it can't be): one process writes at a time.
file_log :: (file: string, format: string, args: ..Any) {
	t := to_calendar(current_time_consensus(), .UTC);
	line := tprint("%-%-% %:%:% %\n", t.year, pad2(t.month_starting_at_0 + 1), pad2(t.day_of_month_starting_at_0 + 1),
		pad2(t.hour), pad2(t.minute), pad2(t.second), tprint(format, ..args));
	path := tprint("%.log", file);
	f, ok := file_open(path, for_writing = true, keep_existing_content = true, log_errors = false);
	if !ok return;
	owner_only(path); // it holds the owner invite
	size := file_length(f);
	if size + line.count > LOG_MAX {
		file_close(*f);
		file_move(path, tprint("%.1", path));
		f, ok = file_open(path, for_writing = true, log_errors = false);
		if !ok return;
		size = 0;
	}
	file_set_position(f, size);
	file_write(*f, line);
	file_close(*f);
}

pad2 :: (n: int) -> string { return tprint("%", formatInt(n, minimum_digits = 2)); }

// set_backup_dir is the -backups:<dir> flag: only whoever starts the server picks where it writes files.
set_backup_dir :: (s: *Server, dir: string) -> bool {
	locks.guard(*s.db_mu);
	return meta_put(s, "host_backup_dir", dir);
}

// set_owner_key is -owner:<key>: whoever can run the server's file names its owner by their key's root (64 hex
// digits), so no bearer invite is needed. A member with that key owns the server at once; anyone else owns it
// when they first join with that key, invite or not, and the one-use owner invite is dropped.
set_owner_key :: (s: *Server, root_hex: string) -> bool, string {
	root: [32]u8;
	if root_hex.count != 64 || !unhex(root_hex, root) return false, "an owner key is 64 hex digits (fastcord -key prints yours)";
	locks.guard(*s.db_mu);
	st := sqlite.prepare(s.db, "SELECT id, name FROM users WHERE root = ? AND left = 0 AND banned = 0;");
	sqlite.bind(st, 1, cast([]u8) root);
	member: s64;
	name: string;
	if sqlite.step(st) == .Row member, name = sqlite.col_int(st, 0), copy_string(sqlite.col_text(st, 1),, temp);
	sqlite.finalize(st);
	ok := sqlite.exec(s.db, "BEGIN;") && sqlite.run(s.db, "DELETE FROM invites WHERE owner = 1;");
	if member ok = ok && meta_put(s, "owner", tprint("%", member)) && sqlite.run(s.db, "DELETE FROM meta WHERE k IN ('owner_root', 'pending_owner', 'pending_owner_nonce');");
	else ok = ok && meta_put(s, "owner_root", root);
	if !ok || !sqlite.exec(s.db, "COMMIT;") { sqlite.exec(s.db, "ROLLBACK;"); return false, copy_string(sqlite.errmsg(s.db),, temp); }
	if member return true, tprint("% now owns the server.", name);
	return true, "The key you named owns the server once it joins, with any invite or none.";
}

// invite_address is where invites send members: the owner's public address and port (Server Settings' Network),
// else localhost and the port served on, for the host to replace.
invite_address :: (s: *Server) -> host: string, port: int {
	locks.guard(*s.db_mu);
	host := copy_string(public_address_locked(s),, temp);
	port := limit_locked(s, "public_port");
	return ifx host then host else "localhost", ifx port then port else s.listener.port;
}

#scope_module

// migrate brings the file to SCHEMA_VERSION: every table, column, index and the search index, in one
// transaction, after a backup when the file already held a server. False with the reason on any failure.
migrate :: (s: *Server, backup := true) -> bool, string {
	db := s.db;
	v := query_int(db, "PRAGMA user_version;");
	if v > SCHEMA_VERSION return false, tprint("it was made by a newer fastcord (schema %, this one reads up to %): update fastcord", v, SCHEMA_VERSION);
	if backup && v < SCHEMA_VERSION && query_int(db, "SELECT count(*) FROM sqlite_master;") > 0 {
		id := meta_get(s, "id"); // the backup's check compares it
		if id.count == 16 memcpy(s.id.data, id.data, 16);
		name, ok, err := backup_locked(s, tprint("pre-v%", SCHEMA_VERSION));
		if !ok return false, tprint("couldn't back it up before updating it: %", err);
		host_log(s, "Backed up to % before updating the file to schema %", name, SCHEMA_VERSION);
	}
	if !sqlite.exec(db, "BEGIN;") return false, copy_string(sqlite.errmsg(db),, temp);
	ok := true;
	for string.[SCHEMA, SOUND_SCHEMA, SETTINGS_SCHEMA, STICKER_SCHEMA, ROLE_SCHEMA, POLL_SCHEMA, THREAD_MEMBER_SCHEMA, DM_SCHEMA] if ok ok = sqlite.exec(db, it);
	for COLUMNS if ok {
		name := it.def;
		space := find_index_from_left(name, #char " ");
		if space >= 0 name.count = space;
		st := sqlite.prepare(db, "SELECT 1 FROM pragma_table_info(?) WHERE name = ?;");
		sqlite.bind_all(st, it.table, name);
		has := sqlite.step(st) == .Row;
		sqlite.finalize(st);
		if !has ok = sqlite.exec(db, tprint("ALTER TABLE % ADD COLUMN %;", it.table, it.def));
	}
	indexed := query_int(db, "SELECT count(*) FROM sqlite_master WHERE name = 'message_text';") > 0;
	ok = ok && sqlite.exec(db, "CREATE INDEX IF NOT EXISTS messages_everyone ON messages(id) WHERE everyone = 1;")
		&& sqlite.exec(db, "CREATE INDEX IF NOT EXISTS messages_nonce ON messages(author, nonce) WHERE nonce IS NOT NULL;")
		&& sqlite.exec(db, SEARCH_SCHEMA)
		&& (indexed || sqlite.exec(db, "INSERT INTO message_text(message_text) VALUES('rebuild');"))
		&& sqlite.exec(db, tprint("PRAGMA user_version = %;", SCHEMA_VERSION))
		&& sqlite.exec(db, "COMMIT;");
	if !ok {
		err := copy_string(sqlite.errmsg(db),, temp);
		sqlite.exec(db, "ROLLBACK;");
		return false, err;
	}
	return true, "";
}

query_int :: (db: *sqlite.DB, sql: string, args: ..Any) -> s64 {
	st := sqlite.prepare(db, sql);
	defer sqlite.finalize(st);
	sqlite.bind_all(st, ..args);
	if sqlite.step(st) != .Row return 0;
	return sqlite.col_int(st, 0);
}

// ---- Settings, kept in meta as decimal text ----

Limit :: struct { key: string; default: s64; lo: s64; hi: s64; }
LIMITS :: Limit.[
	.{"max_upload_mb", 10, 1, 10},          // Per file; the app checks Discord's 10 MB, so only lower.
	.{"member_quota_mb", 0, 0, 1 << 20},    // Files a member has posted, 0: no cap.
	.{"server_quota_mb", 0, 0, 1 << 20},    // Files everyone has posted, 0: no cap.
	.{"retention_days", 0, 0, 36500},       // Messages older than this are deleted, 0: kept forever.
	.{"cleanup_days", 0, 0, 36500},         // Files older than this are deleted, 0: kept.
	.{"cleanup_mb", 0, 0, 10},              // Files larger than this are deleted, 0: kept.
	.{"backup_every_h", 24, 0, 24 * 365},   // 0: no automatic backups.
	.{"backup_keep", 7, 1, 100},
	.{"public_port", 0, 0, 65535},          // The port invites carry, 0: the one served on.
];

limit_locked :: (s: *Server, key: string) -> s64 {
	for LIMITS if it.key == key {
		raw := cast(string) meta_get(s, tprint("host_%", key));
		if !raw return it.default;
		return clamp(string_to_int(raw, T = s64), it.lo, it.hi);
	}
	assert(false, "unknown host limit %", key);
	return 0;
}

MB :: 1 << 20;
NO_CAP :: 0x7FFF_FFFF_FFFF_FFFF;

// upload_quota_locked is the 40005 check for a member asking to upload bytes more.
upload_quota_ok_locked :: (s: *Server, user: s64, bytes: s64) -> bool {
	member, server := limit_locked(s, "member_quota_mb"), limit_locked(s, "server_quota_mb");
	if member && files_bytes_locked(s, user) + bytes > member * MB return false;
	if server && files_bytes_locked(s, 0) + bytes > server * MB return false;
	return true;
}

// files_bytes_locked: what a member's (or with 0, everyone's) posted and pending files take.
files_bytes_locked :: (s: *Server, user: s64) -> s64 {
	if !user return query_int(s.db, "SELECT (SELECT coalesce(sum(size), 0) FROM attachments) + (SELECT coalesce(sum(size), 0) FROM uploads);");
	return query_int(s.db, "SELECT (SELECT coalesce(sum(a.size), 0) FROM attachments a JOIN messages m ON m.id = a.message WHERE m.author = ?1) + (SELECT coalesce(sum(size), 0) FROM uploads WHERE user = ?1);", user);
}

// The address invites carry, if the owner set one; else "".
public_address_locked :: (s: *Server) -> string { return cast(string) meta_get(s, "host_address"); }

// invite_authority_locked is "host:port" for invites when the owner set an address (READY's and GUILD_UPDATE's
// fc_address, so every member's Invite button hands it out), else "".
invite_authority_locked :: (s: *Server) -> string {
	host := public_address_locked(s);
	if !host return "";
	port := limit_locked(s, "public_port");
	if !port port = ifx s.listener then s.listener.port else 0;
	return tprint("%:%", ifx contains(host, ":") then tprint("[%]", host) else copy_string(host,, temp), port);
}

// ---- Backups ----

backup_dir_locked :: (s: *Server) -> string {
	dir := cast(string) meta_get(s, "host_backup_dir");
	if dir return dir;
	return tprint("%-backups", path_strip_extension(s.host.path));
}

Snapshot :: struct { name: string; bytes: s64; time: Apollo_Time; }

snapshot_prefix :: (s: *Server) -> string { return tprint("%-", path_strip_extension(path_filename(s.host.path))); }

// snapshots lists the backups in the folder, oldest first (their names sort by time).
snapshots_locked :: (s: *Server) -> [..]Snapshot {
	out: [..]Snapshot;
	out.allocator = temp;
	prefix := snapshot_prefix(s);
	dir := backup_dir_locked(s);
	if !file_exists(dir) return out;
	for file_list(dir,, temp) {
		name := path_filename(it);
		if !begins_with(name, prefix) || !ends_with(name, ".db") continue;
		t, size, ok := file_modtime_and_size(it);
		if ok array_add(*out, .{copy_string(name,, temp), size, t});
	}
	quick_sort(out, (a, b) => compare(a.name, b.name));
	return out;
}

// backup_locked writes a snapshot with VACUUM INTO, checks it with integrity_check, and keeps only the
// newest backup_keep. The caller holds db_mu.
backup_locked :: (s: *Server, label := "") -> name: string, ok: bool, error: string {
	dir := backup_dir_locked(s);
	if !make_directory_if_it_does_not_exist(dir, recursive = true) return "", false, tprint("can't make the folder %", dir);
	t := to_calendar(current_time_consensus(), .UTC);
	base := tprint("%1%2%3%4-%5%6%7%8", snapshot_prefix(s), t.year, pad2(t.month_starting_at_0 + 1), pad2(t.day_of_month_starting_at_0 + 1),
		pad2(t.hour), pad2(t.minute), pad2(t.second), ifx label then tprint("-%", label) else "");
	name := tprint("%.db", base);
	for 2..9 if file_exists(tprint("%/%", dir, name)) name = tprint("%-%.db", base, it);
	path := tprint("%/%", dir, name);
	if !sqlite.run(s.db, "VACUUM INTO ?;", path) return "", false, copy_string(sqlite.errmsg(s.db),, temp);
	owner_only(path);
	ok, why := snapshot_ok(s, path);
	if !ok { file_delete(path); return "", false, why; }
	list := snapshots_locked(s);
	keep := limit_locked(s, "backup_keep");
	for list if it_index < list.count - keep file_delete(tprint("%/%", dir, it.name));
	return name, true, "";
}

// snapshot_ok opens a snapshot read-only: whole, this server's, and a schema this fastcord reads.
snapshot_ok :: (s: *Server, path: string) -> bool, string {
	db, ok, err := sqlite.open(path, readonly = true);
	if !ok return false, err;
	defer sqlite.close(db);
	st := sqlite.prepare(db, "PRAGMA integrity_check;");
	whole := sqlite.step(st) == .Row && sqlite.col_text(st, 0) == "ok";
	sqlite.finalize(st);
	if !whole return false, "it failed SQLite's integrity check";
	st = sqlite.prepare(db, "SELECT v FROM meta WHERE k = 'id';");
	same := sqlite.step(st) == .Row && sqlite.col_blob(st, 0).count == 16 && memcmp(sqlite.col_blob(st, 0).data, s.id.data, 16) == 0;
	sqlite.finalize(st);
	if !same return false, "it's another server's file";
	if query_int(db, "PRAGMA user_version;") > SCHEMA_VERSION return false, "a newer fastcord made it";
	return true, "";
}

// restore puts a snapshot's contents in place of the server's, in one transaction, after a backup of the
// state it replaces. Sessions still valid on members that exist in the snapshot stay, so nobody signs in
// again; every gateway is then closed so each member reconnects to the restored server.
restore :: (s: *Server, name: string) -> bool, string {
	if !name || contains(name, "/") || contains(name, "\\") || !begins_with(name, snapshot_prefix(s)) || !ends_with(name, ".db") return false, "no such backup";
	{
		locks.guard(*s.db_mu);
		dir := backup_dir_locked(s);
		path := tprint("%/%", dir, name);
		if !file_exists(path) return false, "no such backup";
		ok, why := snapshot_ok(s, path);
		if !ok return false, why;
		// An older schema is brought up to date in a copy first, so its columns line up with the file's.
		copy := tprint("%/restoring.db", dir);
		file_delete(copy);
		defer file_delete(copy);
		src, opened, err := sqlite.open(path, readonly = true);
		if !opened return false, err;
		ok = sqlite.run(src, "VACUUM INTO ?;", copy);
		sqlite.close(src);
		if !ok return false, "couldn't copy the backup";
		{
			// migrate works on a Server; the copy gets a stand-in with only its file.
			t: Server;
			t.db, opened, err = sqlite.open(copy);
			if !opened return false, err;
			migrated, merr := migrate(*t, backup = false);
			sqlite.close(t.db);
			if !migrated return false, merr;
		}
		before, saved, berr := backup_locked(s, "pre-restore");
		if !saved return false, tprint("couldn't back up the current state first: %", berr);
		tables: [..]string;
		tables.allocator = temp;
		st := sqlite.prepare(s.db, "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'message_text%';");
		while sqlite.step(st) == .Row array_add(*tables, copy_string(sqlite.col_text(st, 0),, temp));
		sqlite.finalize(st);
		if !sqlite.run(s.db, "ATTACH ? AS snap;", copy) return false, copy_string(sqlite.errmsg(s.db),, temp);
		ok = sqlite.exec(s.db, "BEGIN;") && sqlite.exec(s.db, "PRAGMA defer_foreign_keys = ON;")
			&& sqlite.exec(s.db, "CREATE TEMP TABLE kept_sessions AS SELECT * FROM main.sessions;");
		for tables if ok {
			cols: [..]string;
			cols.allocator = temp;
			c := sqlite.prepare(s.db, "SELECT name FROM pragma_table_info(?);");
			sqlite.bind(c, 1, it);
			while sqlite.step(c) == .Row array_add(*cols, tprint("\"%\"", sqlite.col_text(c, 0)));
			sqlite.finalize(c);
			list := join(..cols, ", ",, temp);
			ok = sqlite.exec(s.db, tprint("DELETE FROM main.\"%\";", it))
				&& (query_int(s.db, "SELECT count(*) FROM snap.sqlite_master WHERE type = 'table' AND name = ?;", it) == 0
					|| sqlite.exec(s.db, tprint("INSERT INTO main.\"%1\"(%2) SELECT %2 FROM snap.\"%1\";", it, list)));
		}
		ok = ok && sqlite.exec(s.db, "INSERT OR IGNORE INTO main.sessions SELECT * FROM temp.kept_sessions WHERE user IN (SELECT id FROM main.users);")
			&& sqlite.exec(s.db, "DROP TABLE temp.kept_sessions;")
			&& sqlite.exec(s.db, "COMMIT;");
		if !ok {
			err = copy_string(sqlite.errmsg(s.db),, temp);
			sqlite.exec(s.db, "ROLLBACK;");
			sqlite.exec(s.db, "DROP TABLE IF EXISTS temp.kept_sessions;");
			sqlite.exec(s.db, "DETACH snap;");
			return false, err;
		}
		sqlite.exec(s.db, "DETACH snap;");
		load_caches_locked(s);
		host_log(s, "Restored % (the state before it is in %)", name, before);
	}
	locks.guard(*s.mu);
	for s.conns if it.ws netio.shutdown(netio.tcp_stream(it.tcp));
	return true, "";
}

// load_caches_locked reads what open keeps in memory: the name, avatars and handles, and the last ID.
load_caches_locked :: (s: *Server) {
	free(s.name);
	s.name = copy_string(cast(string) meta_get(s, "name"));
	last := query_int(s.db, "SELECT max((SELECT coalesce(max(id), 0) FROM users), (SELECT coalesce(max(id), 0) FROM channels), (SELECT coalesce(max(id), 0) FROM attachments), (SELECT coalesce(max(max(id), coalesce(max(edited), 0), coalesce(max(pinned_at), 0)), 0) FROM messages));");
	while true {
		was := atomic_read(*s.last_id);
		if compare_and_swap(*s.last_id, was, max(was, s.guild, last)) break;
	}
	locks.guard(*s.avatar_mu);
	for s.avatars free(it);
	table_reset(*s.avatars);
	table_reset(*s.handles);
	st := sqlite.prepare(s.db, "SELECT id, avatar FROM users WHERE avatar IS NOT NULL;");
	while sqlite.step(st) == .Row table_set(*s.avatars, sqlite.col_int(st, 0), copy_string(sqlite.col_text(st, 1)));
	sqlite.finalize(st);
	st = sqlite.prepare(s.db, "SELECT u.id, u.root FROM users u WHERE NOT EXISTS(SELECT 1 FROM webhooks w WHERE w.id = u.id);");
	while sqlite.step(st) == .Row table_set(*s.handles, sqlite.col_int(st, 0), member_handle(sqlite.col_blob(st, 1)));
	sqlite.finalize(st);
}

// ---- Cleanup ----

CLEANUP_BATCH :: 500; // Messages or files per pass, so one pass never holds db_mu for long.

Changed :: struct { deleted: [..]Gone_Messages; updated: [..]s64; bytes: s64; }
Gone_Messages :: struct { channel: s64; ids: [..]s64; }

// drop_attachments_locked deletes files by ID. A message left with neither text nor files goes too, as on
// Discord; the others are sent again without them.
drop_attachments_locked :: (s: *Server, ids: []s64, out: *Changed) -> bool {
	if !ids.count return true;
	set: String_Builder;
	set.allocator = temp;
	for ids print_to_builder(*set, "%1%2", ifx it_index then "," else "", it);
	list := builder_to_string(*set,, temp);
	messages: [..]s64;
	messages.allocator = temp;
	st := sqlite.prepare(s.db, tprint("SELECT DISTINCT message FROM attachments WHERE id IN (%);", list));
	while sqlite.step(st) == .Row array_add(*messages, sqlite.col_int(st, 0));
	sqlite.finalize(st);
	out.bytes += query_int(s.db, tprint("SELECT coalesce(sum(size), 0) FROM attachments WHERE id IN (%);", list));
	if !sqlite.exec(s.db, "BEGIN;") return false;
	ok := sqlite.exec(s.db, tprint("DELETE FROM attachments WHERE id IN (%);", list))
		&& sqlite.exec(s.db, tprint("DELETE FROM snapshot_files WHERE attachment IN (%);", list));
	empty: [..]s64;
	empty.allocator = temp;
	for messages if ok {
		if query_int(s.db, "SELECT content = '' AND NOT EXISTS(SELECT 1 FROM attachments WHERE message = ?1) AND (stickers IS NULL OR stickers = '') AND snapshot IS NULL FROM messages WHERE id = ?1;", it) array_add(*empty, it);
		else array_add(*out.updated, it);
	}
	ok = ok && delete_messages_locked(s, empty, out) && sqlite.exec(s.db, "COMMIT;");
	if !ok sqlite.exec(s.db, "ROLLBACK;");
	return ok;
}

// delete_messages_locked deletes messages as a delete from the app does, inside the caller's transaction,
// and notes them per channel for MESSAGE_DELETE_BULK.
delete_messages_locked :: (s: *Server, ids: []s64, out: *Changed) -> bool {
	for ids {
		channel := query_int(s.db, "SELECT channel FROM messages WHERE id = ?;", it);
		ok := sqlite.run(s.db, "DELETE FROM messages WHERE id = ?;", it)
			&& sqlite.run(s.db, "DELETE FROM reactions WHERE message = ?;", it)
			&& sqlite.run(s.db, "DELETE FROM mentions WHERE message = ?;", it)
			&& drop_files(s, "?1", it)
			&& sqlite.run(s.db, "DELETE FROM embeds WHERE message = ?;", it);
		if !ok return false;
		g: *Gone_Messages;
		for * out.deleted if it.channel == channel g = it;
		if !g { g = array_add(*out.deleted); g.channel = channel; g.ids.allocator = temp; }
		array_add(*g.ids, it);
	}
	return true;
}

// announce sends what a cleanup changed, once db_mu is let go.
announce :: (s: *Server, out: Changed) {
	for g: out.deleted {
		ids: [..]etf.Value;
		ids.allocator = temp;
		for g.ids array_add(*ids, snow(it));
		d := etf.map_builder(3,, temp);
		etf.map_put(*d, "ids", etf.vlist(ids));
		etf.map_put(*d, "channel_id", snow(g.channel));
		etf.map_put(*d, "guild_id", snow(s.guild));
		broadcast(s, "MESSAGE_DELETE_BULK", etf.vmap(etf.map_done(*d)));
	}
	for out.updated {
		m: etf.Value;
		{
			locks.guard(*s.db_mu);
			m = message_locked(s, it, nested = false);
		}
		if m.kind == .Map broadcast(s, "MESSAGE_UPDATE", m);
	}
}

// cleanup runs the owner's rules once: messages past retention, files past the age or size limit. It
// returns the bytes of files freed; the space comes back to the disk at the next VACUUM.
cleanup :: (s: *Server) -> s64 {
	out: Changed;
	out.deleted.allocator, out.updated.allocator = temp, temp;
	{
		locks.guard(*s.db_mu);
		days, file_days, file_mb := limit_locked(s, "retention_days"), limit_locked(s, "cleanup_days"), limit_locked(s, "cleanup_mb");
		day_ms :: 86400 * 1000;
		ids: [..]s64;
		ids.allocator = temp;
		if file_days || file_mb {
			old := ifx file_days then (now_ms(s) - file_days * day_ms) << 22 else -1;
			big := ifx file_mb then file_mb * MB else NO_CAP;
			st := sqlite.prepare(s.db, tprint("SELECT id FROM attachments WHERE message < ? OR size > ? LIMIT %;", CLEANUP_BATCH));
			sqlite.bind_all(st, old, big);
			while sqlite.step(st) == .Row array_add(*ids, sqlite.col_int(st, 0));
			sqlite.finalize(st);
			drop_attachments_locked(s, ids, *out);
		}
		if days {
			ids.count = 0;
			st := sqlite.prepare(s.db, tprint("SELECT id FROM messages WHERE id < ? AND id NOT IN (SELECT id FROM channels) LIMIT %;", CLEANUP_BATCH));
			sqlite.bind_all(st, (now_ms(s) - days * day_ms) << 22);
			while sqlite.step(st) == .Row array_add(*ids, sqlite.col_int(st, 0));
			sqlite.finalize(st);
			out.bytes += query_int(s.db, tprint("SELECT coalesce(sum(size), 0) FROM attachments WHERE message IN (%);", join_ids(ids)));
			if ids.count {
				ok := sqlite.exec(s.db, "BEGIN;") && delete_messages_locked(s, ids, *out) && sqlite.exec(s.db, "COMMIT;");
				if !ok sqlite.exec(s.db, "ROLLBACK;");
			}
		}
	}
	announce(s, out);
	if out.deleted.count || out.updated.count host_log(s, "Cleanup deleted % messages and freed % bytes of files", count_ids(out.deleted), out.bytes);
	return out.bytes;
}

join_ids :: (ids: []s64) -> string {
	b: String_Builder;
	b.allocator = temp;
	for ids print_to_builder(*b, "%1%2", ifx it_index then "," else "", it);
	return builder_to_string(*b,, temp);
}

count_ids :: (gone: []Gone_Messages) -> int { n := 0; for gone n += it.ids.count; return n; }

// vacuum gives the space freed pages hold back to the disk. It rewrites the file, so it waits for a
// quiet moment: the maintenance thread runs it, never a request.
vacuum_if_worth_it :: (s: *Server) {
	locks.guard(*s.db_mu);
	free_pages := query_int(s.db, "PRAGMA freelist_count;");
	page := query_int(s.db, "PRAGMA page_size;");
	if free_pages * page < 64 * MB && free_pages * 4 < query_int(s.db, "PRAGMA page_count;") return;
	if sqlite.exec(s.db, "VACUUM;") host_log(s, "Vacuumed: % bytes back to the disk", free_pages * page);
}

// maintain runs on its own thread: backups when due, the cleanup rules hourly, then VACUUM if worth it.
maintain :: (s: *Server) {
	next_cleanup := current_time_monotonic();
	while true {
		reset_temporary_storage();
		{
			locks.guard(*s.db_mu);
			every := limit_locked(s, "backup_every_h");
			list := snapshots_locked(s);
			due := !list.count || to_seconds(current_time_consensus() - list[list.count - 1].time) > every * 3600;
			if every && due {
				name, ok, err := backup_locked(s);
				if ok host_log(s, "Backed up to %", name);
				else host_log(s, "Backup failed: %", err);
			}
		}
		if current_time_monotonic() >= next_cleanup {
			cleanup(s);
			vacuum_if_worth_it(s);
			empty_trash(s.host.path);
			next_cleanup = current_time_monotonic() + seconds_to_apollo(3600);
		}
		locks.lock(*s.host.maint_mu);
		if !s.host.maint_stop locks.cond_wait_with_timeout(*s.host.maint_wake, *s.host.maint_mu, 60_000);
		stop := s.host.maint_stop;
		locks.unlock(*s.host.maint_mu);
		if stop return;
	}
}

maintain_stop :: (s: *Server) {
	if !s.host.maint_thread return;
	locks.lock(*s.host.maint_mu);
	s.host.maint_stop = true;
	locks.cond_signal(*s.host.maint_wake);
	locks.unlock(*s.host.maint_mu);
	locks.join(s.host.maint_thread);
}

// owner_only makes a file readable by its owner alone: the server file, its backups (each holds the TLS key)
// and its log. On Windows, the user's folders already are.
owner_only :: (path: string) {
	#if OS != .WINDOWS chmod(temp_c_string(path), 0x180); // 0600
}

// ---- Disk space ----

disk_free :: (dir: string) -> s64 {
	#if OS == .WINDOWS {
		free_bytes: u64;
		if !GetDiskFreeSpaceExW(utf8_to_wide(dir,, temp), *free_bytes, null, null) return -1;
		return xx free_bytes;
	} else {
		buf: [256]u8 #align 8; // struct statvfs, read by its first fields
		if statvfs(temp_c_string(dir), buf.data) != 0 return -1;
		#if OS == .MACOS {
			frsize := (cast(*u64) (buf.data + 8)).*;
			avail := (cast(*u32) (buf.data + 24)).*; // fsblkcnt_t is 32-bit here
			return xx (frsize * avail);
		} else {
			frsize := (cast(*u64) (buf.data + 8)).*;
			avail := (cast(*u64) (buf.data + 32)).*;
			return xx (frsize * avail);
		}
	}
}

#if OS == .WINDOWS {
	kernel32 :: #system_library "kernel32";
	GetDiskFreeSpaceExW :: (dir: *u16, free_to_caller: *u64, total: *u64, total_free: *u64) -> s32 #foreign kernel32;
	#import "Windows_Utf8";
} else {
	host_libc :: #system_library "libc";
	statvfs :: (path: *u8, buf: *void) -> s32 #foreign host_libc;
	chmod :: (path: *u8, mode: u32) -> s32 #foreign host_libc; // mode_t is narrower on macOS; the ABI widens it
}

// ---- Routes: /api/v9/fc/host/..., owner only ----

HOST_BASE :: "/api/v9/fc/host";
ATTACHMENTS_PAGE :: 100;

host_route :: (c: *Conn, req: http.Request) -> bool {
	s := c.server;
	token, _ := http.header_get(req.headers, "authorization");
	user := session_user(c, token);
	if !user return json_error(c, 401, 0, "401: Unauthorized");
	{
		locks.guard(*s.db_mu);
		if user != owner_id(s) return json_error(c, 403, 50013, "Missing Permissions");
	}
	path := advance(req.path, HOST_BASE.count);
	query := "";
	q := find_index_from_left(path, #char "?");
	if q >= 0 { query = advance(path, q + 1); path.count = q; }
	if path == "" && req.method == "GET" return host_info(c);
	if path == "" && req.method == "PATCH" return host_settings(c, req);
	if path == "/attachments" && req.method == "GET" return host_attachments(c, query);
	if path == "/attachments/delete" && req.method == "POST" return host_delete_attachments(c, req);
	if path == "/cleanup" && req.method == "POST" {
		freed := cleanup(s);
		vacuum_if_worth_it(s);
		m := etf.map_builder(1,, temp);
		etf.map_put(*m, "freed_bytes", etf.vint(freed));
		return json_reply(c, 200, etf.vmap(etf.map_done(*m)));
	}
	if path == "/backups" && req.method == "GET" return host_backups(c);
	if path == "/backups" && req.method == "POST" {
		name, err: string;
		ok: bool;
		{
			locks.guard(*s.db_mu);
			name, ok, err = backup_locked(s);
		}
		if !ok return host_error(c, 500, tprint("Backup failed: %", err));
		host_log(s, "Backed up to % (Back Up Now)", name);
		return host_backups(c);
	}
	if begins_with(path, "/backups/") && ends_with(path, "/restore") && req.method == "POST" {
		name := percent_decode(slice(path, "/backups/".count, path.count - "/backups/".count - "/restore".count));
		ok, err := restore(s, name);
		if !ok return host_error(c, 400, tprint("Restore failed: %", err));
		return respond(c, 204, json = false);
	}
	if path == "/sessions" && req.method == "GET" return host_sessions(c);
	if begins_with(path, "/sessions/") && req.method == "DELETE" {
		target, ok := string_to_int(advance(path, "/sessions/".count), T = s64);
		if !ok return json_error(c, 404, 0, "404: Not Found");
		{
			locks.guard(*s.db_mu);
			sqlite.run(s.db, "DELETE FROM sessions WHERE user = ?;", target);
		}
		{
			locks.guard(*s.mu);
			for s.conns if it.user == target && it != c netio.shutdown(netio.tcp_stream(it.tcp));
		}
		host_log(s, "The owner ended %'s sessions", target);
		return respond(c, 204, json = false);
	}
	if path == "/log" && req.method == "GET" return host_log_tail(c);
	if path == "/delete" && req.method == "POST" return host_delete(c, req);
	return json_error(c, 404, 0, "404: Not Found");
}

// host_error is json_error for a message that may hold quotes: a path or SQLite's own words.
host_error :: (c: *Conn, status: int, message: string) -> bool {
	m := etf.map_builder(2,, temp);
	etf.map_put(*m, "message", etf.vstring(message));
	etf.map_put(*m, "code", etf.vint(0));
	return json_reply(c, status, etf.vmap(etf.map_done(*m)));
}

// GET: Server info, Storage, Limits and Network in one reply.
host_info :: (c: *Conn) -> bool {
	s := c.server;
	locks.guard(*s.db_mu);
	page := query_int(s.db, "PRAGMA page_size;");
	file := query_int(s.db, "PRAGMA page_count;") * page;
	m := etf.map_builder(24,, temp);
	etf.map_put(*m, "version", etf.vstring(s.host.version));
	etf.map_put(*m, "schema", etf.vint(SCHEMA_VERSION));
	etf.map_put(*m, "uptime_s", etf.vint(to_seconds(current_time_consensus() - s.host.started)));
	etf.map_put(*m, "file", etf.vstring(s.host.path));
	etf.map_put(*m, "id", etf.vstring(id_hex(s)));
	etf.map_put(*m, "pin", etf.vstring(pin_hex(s)));
	etf.map_put(*m, "webhook_pin", etf.vstring(webhook_pin(s)));
	etf.map_put(*m, "port", etf.vint(ifx s.listener then s.listener.port else 0));
	etf.map_put(*m, "address", etf.vstring(public_address_locked(s)));
	etf.map_put(*m, "backup_dir", etf.vstring(backup_dir_locked(s)));
	etf.map_put(*m, "file_bytes", etf.vint(file));
	etf.map_put(*m, "disk_free_bytes", etf.vint(disk_free(path_strip_filename_or_dot(s.host.path))));
	st := etf.map_builder(10,, temp);
	BLOBS :: string.[
		"messages", "SELECT coalesce(sum(length(content) + coalesce(length(snapshot), 0)), 0) FROM messages",
		"attachments", "SELECT coalesce(sum(length(data)), 0) FROM attachments",
		"uploads", "SELECT coalesce(sum(length(data)), 0) FROM uploads",
		"emoji", "SELECT coalesce(sum(length(data)), 0) FROM emojis",
		"stickers", "SELECT coalesce(sum(length(data)), 0) FROM stickers",
		"sounds", "SELECT coalesce(sum(length(data)), 0) FROM sounds",
		"avatars", "SELECT coalesce(sum(length(avatar_data)), 0) + (SELECT coalesce(sum(length(icon_data)), 0) FROM groups) FROM users",
	];
	used := 0;
	for i: 0..BLOBS.count / 2 - 1 {
		n := query_int(s.db, BLOBS[2 * i + 1]);
		used += n;
		etf.map_put(*st, BLOBS[2 * i], etf.vint(n));
	}
	free_bytes := query_int(s.db, "PRAGMA freelist_count;") * page;
	etf.map_put(*st, "free", etf.vint(free_bytes));
	etf.map_put(*st, "other", etf.vint(max(0, file - used - free_bytes))); // the search index, tables' structure
	etf.map_put(*m, "storage", etf.vmap(etf.map_done(*st)));
	lim := etf.map_builder(LIMITS.count,, temp);
	for LIMITS etf.map_put(*lim, it.key, etf.vint(limit_locked(s, it.key)));
	etf.map_put(*m, "limits", etf.vmap(etf.map_done(*lim)));
	return json_reply(c, 200, etf.vmap(etf.map_done(*m)));
}

path_strip_filename_or_dot :: (path: string) -> string {
	dir := path_strip_filename(path);
	return ifx dir then dir else ".";
}

// PATCH {<limit>: n, address?: "host"}: Limits and Network. Values out of range are refused, not clamped.
host_settings :: (c: *Conn, req: http.Request) -> bool {
	s := c.server;
	v, err := etf.from_json(cast(string) req.body,, temp);
	if err != .None || v.kind != .Map return json_error(c, 400, 50035, "Invalid Form Body");
	g := etf.map_builder(2,, temp);
	etf.map_put(*g, "id", snow(s.guild));
	{
		locks.guard(*s.db_mu);
		for p: v.map {
			if p.key.kind != .String return json_error(c, 400, 50035, "Invalid Form Body");
			if p.key.s == "address" {
				if p.value.kind != .String || !address_ok(p.value.s) return json_error(c, 400, 50035, "Invalid Form Body");
				continue;
			}
			known := false;
			for LIMITS if it.key == p.key.s {
				known = true;
				if p.value.kind != .Int || p.value.i < it.lo || p.value.i > it.hi return json_error(c, 400, 50035, "Invalid Form Body");
			}
			if !known return json_error(c, 400, 50035, "Invalid Form Body");
		}
		if !sqlite.exec(s.db, "BEGIN;") return json_error(c, 500, 0, "500: Internal Server Error");
		ok := true;
		for p: v.map if ok {
			if p.key.s == "address" ok = meta_put(s, "host_address", p.value.s);
			else ok = meta_put(s, tprint("host_%", p.key.s), tprint("%", p.value.i));
		}
		if !ok || !sqlite.exec(s.db, "COMMIT;") { sqlite.exec(s.db, "ROLLBACK;"); return json_error(c, 500, 0, "500: Internal Server Error"); }
		etf.map_put(*g, "fc_address", etf.vstring(invite_authority_locked(s)));
		host_log(s, "The owner changed the host settings: %", cast(string) req.body);
	}
	broadcast(s, "GUILD_UPDATE", etf.vmap(etf.map_done(*g))); // every member's Invite button follows the address
	return respond(c, 204, json = false);
}

// address_ok takes a DNS name or an IP address: what an invite's authority holds, without the port.
address_ok :: (a: string) -> bool {
	if a.count > 253 return false;
	colons := 0;
	for a {
		if it == #char ":" colons += 1;
		else if !is_alnum(it) && it != #char "." && it != #char "-" return false;
	}
	return colons == 0 || colons >= 2; // bare IPv6, or a name / IPv4 with no port
}

// GET ?before=<id>&sort=size: Attachments, newest (or largest) first, a page at a time.
host_attachments :: (c: *Conn, query: string) -> bool {
	s := c.server;
	before: s64 = NO_CAP;
	by_size := false;
	for split(query, "&",, temp) {
		if begins_with(it, "before=") before = string_to_int(advance(it, 7), T = s64);
		if it == "sort=size" by_size = true;
	}
	locks.guard(*s.db_mu);
	sql := tprint("SELECT a.id, a.filename, a.size, a.content_type, a.message, m.channel, coalesce(ch.name, ''), m.author, coalesce(m.username, u.name) FROM attachments a JOIN messages m ON m.id = a.message JOIN users u ON u.id = m.author LEFT JOIN channels ch ON ch.id = m.channel WHERE % ORDER BY % LIMIT %;",
		ifx by_size then "a.size < ?" else "a.id < ?", ifx by_size then "a.size DESC, a.id DESC" else "a.id DESC", ATTACHMENTS_PAGE);
	st := sqlite.prepare(s.db, sql);
	defer sqlite.finalize(st);
	sqlite.bind(st, 1, before);
	list: [..]etf.Value;
	list.allocator = temp;
	while sqlite.step(st) == .Row {
		a := etf.map_builder(9,, temp);
		etf.map_put(*a, "id", snow(sqlite.col_int(st, 0)));
		etf.map_put(*a, "filename", etf.vstring(copy_string(sqlite.col_text(st, 1),, temp)));
		etf.map_put(*a, "size", etf.vint(sqlite.col_int(st, 2)));
		etf.map_put(*a, "content_type", etf.vstring(copy_string(sqlite.col_text(st, 3),, temp)));
		etf.map_put(*a, "message_id", snow(sqlite.col_int(st, 4)));
		etf.map_put(*a, "channel_id", snow(sqlite.col_int(st, 5)));
		etf.map_put(*a, "channel_name", etf.vstring(copy_string(sqlite.col_text(st, 6),, temp)));
		etf.map_put(*a, "uploader_id", snow(sqlite.col_int(st, 7)));
		etf.map_put(*a, "uploader_name", etf.vstring(copy_string(sqlite.col_text(st, 8),, temp)));
		array_add(*list, etf.vmap(etf.map_done(*a)));
	}
	return json_reply(c, 200, etf.vlist(list));
}

// POST /attachments/delete {ids: [..]}: the owner deletes files by hand.
host_delete_attachments :: (c: *Conn, req: http.Request) -> bool {
	s := c.server;
	v, err := etf.from_json(cast(string) req.body,, temp);
	ids_v: etf.Value;
	if err == .None && v.kind == .Map ids_v = etf.map_get(v.map, "ids");
	if ids_v.kind != .List || !ids_v.list.count || ids_v.list.count > ATTACHMENTS_PAGE return json_error(c, 400, 50035, "Invalid Form Body");
	ids: [..]s64;
	ids.allocator = temp;
	for ids_v.list {
		id, ok := string_to_int(it.s, T = s64);
		if it.kind != .String || !ok return json_error(c, 400, 50035, "Invalid Form Body");
		array_add(*ids, id);
	}
	out: Changed;
	out.deleted.allocator, out.updated.allocator = temp, temp;
	{
		locks.guard(*s.db_mu);
		if !drop_attachments_locked(s, ids, *out) return json_error(c, 500, 0, "500: Internal Server Error");
	}
	announce(s, out);
	host_log(s, "The owner deleted % files (% bytes)", ids.count, out.bytes);
	m := etf.map_builder(1,, temp);
	etf.map_put(*m, "freed_bytes", etf.vint(out.bytes));
	return json_reply(c, 200, etf.vmap(etf.map_done(*m)));
}

host_backups :: (c: *Conn) -> bool {
	s := c.server;
	locks.guard(*s.db_mu);
	list: [..]etf.Value;
	list.allocator = temp;
	snaps := snapshots_locked(s);
	for < snaps {
		b := etf.map_builder(3,, temp);
		etf.map_put(*b, "name", etf.vstring(it.name));
		etf.map_put(*b, "size", etf.vint(it.bytes));
		etf.map_put(*b, "time", etf.vint(to_seconds(it.time - APOLLO_TIME_FOR_JAN_1_1970)));
		array_add(*list, etf.vmap(etf.map_done(*b)));
	}
	m := etf.map_builder(2,, temp);
	etf.map_put(*m, "folder", etf.vstring(backup_dir_locked(s)));
	etf.map_put(*m, "backups", etf.vlist(list));
	return json_reply(c, 200, etf.vmap(etf.map_done(*m)));
}

// GET /sessions: who is connected, from where and for how long, one row per gateway.
host_sessions :: (c: *Conn) -> bool {
	s := c.server;
	Row :: struct { user: s64; address: string; seconds: s64; }
	rows: [..]Row;
	rows.allocator = temp;
	{
		locks.guard(*s.mu);
		now := current_time_monotonic();
		for s.conns if it.ws && it.user && !it.text array_add(*rows, .{it.user, address_text(it.tcp.peer), to_seconds(now - it.accepted)});
	}
	locks.guard(*s.db_mu);
	list: [..]etf.Value;
	list.allocator = temp;
	for rows {
		st := sqlite.prepare(s.db, "SELECT name, (SELECT count(*) FROM sessions WHERE user = ?1) FROM users WHERE id = ?1;");
		sqlite.bind(st, 1, it.user);
		r := etf.map_builder(5,, temp);
		etf.map_put(*r, "user_id", snow(it.user));
		if sqlite.step(st) == .Row {
			etf.map_put(*r, "name", etf.vstring(copy_string(sqlite.col_text(st, 0),, temp)));
			etf.map_put(*r, "sessions", etf.vint(sqlite.col_int(st, 1)));
		}
		sqlite.finalize(st);
		etf.map_put(*r, "address", etf.vstring(it.address));
		etf.map_put(*r, "connected_s", etf.vint(it.seconds));
		array_add(*list, etf.vmap(etf.map_done(*r)));
	}
	return json_reply(c, 200, etf.vlist(list));
}

address_text :: (p: [16]u8) -> string {
	if memcmp(p.data, IPV4_MAPPED.data, IPV4_MAPPED.count) == 0 return tprint("%.%.%.%", p[12], p[13], p[14], p[15]);
	b: String_Builder;
	b.allocator = temp;
	for i: 0..7 print_to_builder(*b, "%1%2", ifx i then ":" else "", formatInt((cast(int) p[2 * i] << 8) | p[2 * i + 1], base = 16));
	return builder_to_string(*b,, temp);
}

// POST /delete {name}: Delete Server, with the server's name typed as on Discord. The file is copied to the
// trash (VACUUM INTO), every member is told the guild is gone, and host.deleted tells whoever runs the server to
// stop it and remove the file (finish_delete).
host_delete :: (c: *Conn, req: http.Request) -> bool {
	s := c.server;
	v, err := etf.from_json(cast(string) req.body,, temp);
	name: etf.Value;
	if err == .None && v.kind == .Map name = etf.map_get(v.map, "name");
	{
		locks.guard(*s.db_mu);
		if name.kind != .String || name.s != s.name return json_error(c, 400, 50035, "Invalid Form Body");
		dir := trash_dir(s.host.path);
		t := to_calendar(current_time_consensus(), .UTC);
		to := tprint("%/%-%3%4%5-%6%7%8.db", dir, path_strip_extension(path_filename(s.host.path)), t.year, pad2(t.month_starting_at_0 + 1),
			pad2(t.day_of_month_starting_at_0 + 1), pad2(t.hour), pad2(t.minute), pad2(t.second));
		if !make_directory_if_it_does_not_exist(dir, recursive = true) || file_exists(to) || !sqlite.run(s.db, "VACUUM INTO ?;", to) {
			return host_error(c, 500, tprint("Couldn't move the server to the trash: %", sqlite.errmsg(s.db)));
		}
		owner_only(to);
		host_log(s, "The owner deleted the server; its file is in % for % days", to, TRASH_DAYS);
	}
	g := etf.map_builder(1,, temp);
	etf.map_put(*g, "id", snow(s.guild));
	broadcast(s, "GUILD_DELETE", etf.vmap(etf.map_done(*g)));
	atomic_store(*s.host.deleted, true);
	return respond(c, 204, json = false);
}

// empty_trash drops deleted servers older than TRASH_DAYS from the trash beside file.
empty_trash :: (file: string) {
	dir := trash_dir(file);
	if !file_exists(dir) return;
	for file_list(dir,, temp) {
		t, _, ok := file_modtime_and_size(it);
		if ok && ends_with(it, ".db") && to_seconds(current_time_consensus() - t) > TRASH_DAYS * 86400 file_delete(it);
	}
}

LOG_TAIL :: 16 << 10;

// GET /log: the log's last 16 KB, from a line's start.
host_log_tail :: (c: *Conn) -> bool {
	s := c.server;
	text: string;
	{
		locks.guard(*s.host.log_mu);
		f, ok := file_open(tprint("%.log", s.host.path), log_errors = false);
		if ok {
			size := file_length(f);
			from := max(0, size - LOG_TAIL);
			file_set_position(f, from);
			buf := alloc_string(size - from,, temp);
			_, got := file_read(f, buf.data, buf.count);
			buf.count = got;
			file_close(*f);
			if from {
				nl := find_index_from_left(buf, #char "\n");
				if nl >= 0 buf = advance(buf, nl + 1);
			}
			text = buf;
		}
	}
	m := etf.map_builder(1,, temp);
	etf.map_put(*m, "log", etf.vstring(text));
	return json_reply(c, 200, etf.vmap(etf.map_done(*m)));
}
