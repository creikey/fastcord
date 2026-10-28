/// SQLite (vendor/sqlite, built with FTS5) as plain procedures. A connection is used by one thread at a time.
#import "Basic";

DB :: struct {}
Stmt :: struct {}

// open makes the file if needed, in WAL mode with synchronous=FULL: a commit is on disk before it returns.
// exclusive holds the file locked against every other connection until close; it must be set before WAL
// is entered to take effect at once.
open :: (path: string, exclusive := false) -> *DB, bool {
	db: *DB;
	if sqlite3_open_v2(temp_c_string(path), *db, OPEN_READWRITE | OPEN_CREATE | OPEN_NOMUTEX, null) != OK {
		sqlite3_close_v2(db);
		return null, false;
	}
	sqlite3_busy_timeout(db, 5000);
	ok := (!exclusive || exec(db, "PRAGMA locking_mode=EXCLUSIVE;"))
		&& exec(db, "PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON;");
	if !ok { sqlite3_close_v2(db); return null, false; }
	return db, true;
}

close :: (db: *DB) { sqlite3_close_v2(db); }

exec :: (db: *DB, sql: string) -> bool { return sqlite3_exec(db, temp_c_string(sql), null, null, null) == OK; }

errmsg :: (db: *DB) -> string { return to_string(sqlite3_errmsg(db)); }

prepare :: (db: *DB, sql: string) -> *Stmt {
	st: *Stmt;
	if sqlite3_prepare_v2(db, sql.data, xx sql.count, *st, null) != OK return null;
	return st;
}

finalize :: (st: *Stmt) { sqlite3_finalize(st); }
reset :: (st: *Stmt) { sqlite3_reset(st); sqlite3_clear_bindings(st); }

// bind takes 1-based parameter indices, as SQLite does. Strings and blobs are copied.
bind :: (st: *Stmt, i: int, v: s64) -> bool { return sqlite3_bind_int64(st, xx i, v) == OK; }
// An empty string with a null data pointer would bind as NULL, not ''.
bind :: (st: *Stmt, i: int, v: string) -> bool { return sqlite3_bind_text(st, xx i, ifx v.data then v.data else *empty_text, xx v.count, TRANSIENT) == OK; }
bind :: (st: *Stmt, i: int, v: []u8) -> bool { return sqlite3_bind_blob(st, xx i, v.data, xx v.count, TRANSIENT) == OK; }
bind_null :: (st: *Stmt, i: int) -> bool { return sqlite3_bind_null(st, xx i) == OK; }

// bind_all binds args in order: integers, strings, []u8 blobs, or null pointers for NULL.
bind_all :: (st: *Stmt, args: ..Any) -> bool {
	ok := true;
	for args {
		i := it_index + 1;
		if it.type.type == {
			case .INTEGER;
				v: s64;
				size := it.type.runtime_size;
				signed := (cast(*Type_Info_Integer) it.type).signed;
				if size == 8 v = (cast(*s64) it.value_pointer).*;
				else if size == 4 v = ifx signed then cast(s64) (cast(*s32) it.value_pointer).* else cast(s64) (cast(*u32) it.value_pointer).*;
				else if size == 2 v = ifx signed then cast(s64) (cast(*s16) it.value_pointer).* else cast(s64) (cast(*u16) it.value_pointer).*;
				else v = ifx signed then cast(s64) (cast(*s8) it.value_pointer).* else cast(s64) (cast(*u8) it.value_pointer).*;
				ok &&= bind(st, i, v);
			case .BOOL; ok &&= bind(st, i, cast(s64) ifx (cast(*bool) it.value_pointer).* then 1 else 0);
			case .STRING; ok &&= bind(st, i, (cast(*string) it.value_pointer).*);
			case .ARRAY; ok &&= bind(st, i, (cast(*[]u8) it.value_pointer).*);
			case .POINTER; ok &&= bind_null(st, i);
			case; assert(false, "sqlite.bind_all: unsupported type");
		}
	}
	return ok;
}

Step :: enum u8 { Row; Done; Error; }
step :: (st: *Stmt) -> Step {
	r := sqlite3_step(st);
	return ifx r == ROW then .Row else ifx r == DONE then .Done else .Error;
}

// run prepares, binds, steps once and finalizes: for statements that return no rows.
run :: (db: *DB, sql: string, args: ..Any) -> bool {
	st := prepare(db, sql);
	if !st return false;
	ok := bind_all(st, ..args) && step(st) == .Done;
	finalize(st);
	return ok;
}

// Columns are 0-based. Text and blobs point into the statement: copy them before the next step.
col_int :: (st: *Stmt, i: int) -> s64 { return sqlite3_column_int64(st, xx i); }
col_text :: (st: *Stmt, i: int) -> string {
	p := sqlite3_column_text(st, xx i);
	return .{sqlite3_column_bytes(st, xx i), p};
}
col_blob :: (st: *Stmt, i: int) -> []u8 {
	p := cast(*u8) sqlite3_column_blob(st, xx i);
	return .{sqlite3_column_bytes(st, xx i), p};
}
col_is_null :: (st: *Stmt, i: int) -> bool { return sqlite3_column_type(st, xx i) == NULL_TYPE; }

changes :: (db: *DB) -> int { return sqlite3_changes(db); }

#scope_file

OK :: 0;
ROW :: 100;
DONE :: 101;
NULL_TYPE :: 5;
OPEN_READWRITE :: 0x2;
OPEN_CREATE :: 0x4;
OPEN_NOMUTEX :: 0x8000;
TRANSIENT :: cast(*void) -1;
empty_text: u8;

lib :: #library,no_dll "../../build/fc_vendor";
sqlite3_open_v2 :: (path: *u8, db: **DB, flags: s32, vfs: *u8) -> s32 #foreign lib;
sqlite3_close_v2 :: (db: *DB) -> s32 #foreign lib;
sqlite3_busy_timeout :: (db: *DB, ms: s32) -> s32 #foreign lib;
sqlite3_exec :: (db: *DB, sql: *u8, cb: *void, arg: *void, err: **u8) -> s32 #foreign lib;
sqlite3_errmsg :: (db: *DB) -> *u8 #foreign lib;
sqlite3_prepare_v2 :: (db: *DB, sql: *u8, n: s32, st: **Stmt, tail: **u8) -> s32 #foreign lib;
sqlite3_finalize :: (st: *Stmt) -> s32 #foreign lib;
sqlite3_reset :: (st: *Stmt) -> s32 #foreign lib;
sqlite3_clear_bindings :: (st: *Stmt) -> s32 #foreign lib;
sqlite3_bind_int64 :: (st: *Stmt, i: s32, v: s64) -> s32 #foreign lib;
sqlite3_bind_text :: (st: *Stmt, i: s32, p: *u8, n: s32, dtor: *void) -> s32 #foreign lib;
sqlite3_bind_blob :: (st: *Stmt, i: s32, p: *void, n: s32, dtor: *void) -> s32 #foreign lib;
sqlite3_bind_null :: (st: *Stmt, i: s32) -> s32 #foreign lib;
sqlite3_step :: (st: *Stmt) -> s32 #foreign lib;
sqlite3_column_int64 :: (st: *Stmt, i: s32) -> s64 #foreign lib;
sqlite3_column_text :: (st: *Stmt, i: s32) -> *u8 #foreign lib;
sqlite3_column_blob :: (st: *Stmt, i: s32) -> *void #foreign lib;
sqlite3_column_bytes :: (st: *Stmt, i: s32) -> s32 #foreign lib;
sqlite3_column_type :: (st: *Stmt, i: s32) -> s32 #foreign lib;
sqlite3_changes :: (db: *DB) -> s32 #foreign lib;
