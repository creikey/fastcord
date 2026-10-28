/// End-to-end encrypted DMs (TODO.md E2E 1-8). E2E 1: the client database `<state>/fastcord.db` on its own thread.
#import "Basic";
#import "Atomics";
#import "Thread";
#import "File";
#import "String";
locks :: #import "locks";
sqlite :: #import "sqlite";

// A Job runs on the database thread, in the order submitted, so a write submitted before a send is
// committed before anything submitted after it runs. Embed it with #as and add the job's own fields:
// the caller owns the memory and may free it once done is set.
Job :: struct {
	run: (db: *sqlite.DB, job: *Job);
	done: s32;
	failed: bool; // The database couldn't be opened: run was skipped.
}

Db :: struct {
	path: string;
	wake: (); // Called on the database thread after each job, e.g. to request a UI frame.
	thread: *Thread;
	mu: locks.Mutex;
	cond: locks.Cond;
	queue: [..]*Job;
	stopping: bool;
	stopped: s32;
	error: string; // Set by the database thread before it marks jobs failed; read it after a job's done.
}

// start opens path (":memory:" for headless runs) on a new thread and migrates it. It never waits on disk.
start :: (path: string, wake: () = null) -> *Db {
	d := New(Db);
	d.path = copy_string(path);
	d.wake = wake;
	d.thread = New(Thread);
	d.thread.data = d;
	thread_init(d.thread, (t: *Thread) -> s64 { loop(cast(*Db) t.data); return 0; });
	thread_start(d.thread);
	return d;
}

submit :: (d: *Db, job: *Job) {
	assert(job.run != null);
	locks.guard(*d.mu);
	assert(!d.stopping, "e2e.submit after stop");
	array_add(*d.queue, job);
	locks.cond_signal(*d.cond);
}

is_done :: (job: *Job) -> bool { return atomic_load(*job.done) != 0; }

// stop runs the jobs already queued, checkpoints the WAL into the main file and closes it.
// Poll stopped, then free with destroy.
stop :: (d: *Db) {
	locks.guard(*d.mu);
	d.stopping = true;
	locks.cond_signal(*d.cond);
}

stopped :: (d: *Db) -> bool { return atomic_load(*d.stopped) != 0; }

destroy :: (d: *Db) {
	assert(stopped(d));
	thread_deinit(d.thread);
	free(d.thread);
	free(d.path);
	free(d.error);
	array_free(d.queue);
	free(d);
}

#scope_file

// Each entry moves the schema up one version (PRAGMA user_version). Never edit a shipped entry; append.
MIGRATIONS :: string.[
	"CREATE TABLE meta(key TEXT PRIMARY KEY, value BLOB NOT NULL) WITHOUT ROWID;",
];

loop :: (d: *Db) {
	if d.path != ":memory:" make_directory_if_it_does_not_exist(path_strip_filename(d.path), recursive = true);
	// Exclusive: a second fastcord on the same <state> gets no database, rather than two processes
	// advancing one ratchet and encrypting two messages under the same key.
	db, ok := sqlite.open(d.path, exclusive = true);
	if !ok {
		d.error = sprint("cannot open % (damaged, or in use by another fastcord)", d.path);
	} else if !migrate(db) {
		d.error = sprint("cannot migrate %: %", d.path, sqlite.errmsg(db));
		sqlite.close(db);
		db, ok = null, false;
	}
	if !ok log_error("e2e: %", d.error);
	while true {
		reset_temporary_storage();
		locks.lock(*d.mu);
		while !d.queue.count && !d.stopping locks.cond_wait(*d.cond, *d.mu);
		if !d.queue.count { locks.unlock(*d.mu); break; }
		job := d.queue[0];
		array_ordered_remove_by_index(*d.queue, 0);
		locks.unlock(*d.mu);
		if ok job.run(db, job);
		else job.failed = true;
		atomic_store(*job.done, 1);
		if d.wake d.wake();
	}
	if ok {
		// TRUNCATE leaves the main file complete on its own, so a copy of it alone loses nothing.
		sqlite.exec(db, "PRAGMA wal_checkpoint(TRUNCATE);");
		sqlite.close(db);
	}
	atomic_store(*d.stopped, 1);
	if d.wake d.wake();
}

migrate :: (db: *sqlite.DB) -> bool {
	st := sqlite.prepare(db, "PRAGMA user_version;");
	if !st return false;
	version := ifx sqlite.step(st) == .Row then sqlite.col_int(st, 0) else -1;
	sqlite.finalize(st);
	if version < 0 return false;
	if version > MIGRATIONS.count {
		log_error("e2e: the database is schema version %, newer than this fastcord's %", version, MIGRATIONS.count);
		return false;
	}
	for i: version..MIGRATIONS.count-1 {
		ok := sqlite.exec(db, "BEGIN;") && sqlite.exec(db, MIGRATIONS[i])
			&& sqlite.exec(db, tprint("PRAGMA user_version = %;", i + 1)) && sqlite.exec(db, "COMMIT;");
		if !ok { sqlite.exec(db, "ROLLBACK;"); return false; }
	}
	return true;
}
