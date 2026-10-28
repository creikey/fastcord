// E2E module check: jai build.jai - run src/tests/e2e.jai, then build/e2e.exe. Writes only under build/e2e_test.
#import "Basic";
#import "File";
#import "File_Utilities";
e2e :: #import "e2e";
sqlite :: #import "sqlite";
#if OS == .WINDOWS msvcprt :: #library,system,no_dll,link_always "msvcprt";

Put :: struct { #as using job: e2e.Job; value: s64; ok: bool; }
Get :: struct { #as using job: e2e.Job; value: s64; found: bool; }

main :: () {
	failed := 0;
	check :: (ok: bool, what: string) #expand {
		if !ok { print("FAIL: %\n", what); `failed += 1; }
	}
	wait :: (j: *e2e.Job) { while !e2e.is_done(j) sleep_milliseconds(1); }

	dir := "build/e2e_test";
	delete_directory(dir);
	path := tprint("%/sub/fastcord.db", dir);

	d := e2e.start(path);
	puts: [3]Put;
	for *puts {
		it.value = it_index + 1;
		it.run = (db: *sqlite.DB, j: *e2e.Job) {
			p := cast(*Put) j;
			p.ok = sqlite.run(db, "INSERT OR REPLACE INTO meta(key, value) VALUES('n', ?);", p.value);
		};
		e2e.submit(d, it);
	}
	e2e.stop(d);
	while !e2e.stopped(d) sleep_milliseconds(1);
	for puts check(e2e.is_done(*it) && !it.failed && it.ok, "queued jobs run before stop");
	e2e.destroy(d);
	wal := file_exists(tprint("%-wal", path)) && read_entire_file(tprint("%-wal", path)).count > 0;
	check(!wal, "WAL checkpointed into the main file on stop");

	d = e2e.start(path);
	g: Get;
	g.run = (db: *sqlite.DB, j: *e2e.Job) {
		g := cast(*Get) j;
		st := sqlite.prepare(db, "SELECT value FROM meta WHERE key = 'n';");
		if sqlite.step(st) == .Row { g.found = true; g.value = sqlite.col_int(st, 0); }
		sqlite.finalize(st);
	};
	e2e.submit(d, *g);
	wait(*g);
	check(g.found && g.value == 3, "jobs run in order and persist across a reopen");

	// A second connection to the same file, as a second fastcord on one <state> would make, is refused.
	d2 := e2e.start(path);
	g2: Get;
	g2.run = g.run;
	e2e.submit(d2, *g2);
	wait(*g2);
	check(g2.failed, "second opener of a held database fails");
	e2e.stop(d2);
	while !e2e.stopped(d2) sleep_milliseconds(1);
	e2e.destroy(d2);
	e2e.stop(d);
	while !e2e.stopped(d) sleep_milliseconds(1);
	e2e.destroy(d);

	// A path that can't be a database fails every job instead of running it.
	write_entire_file(tprint("%/bad.db", dir), "not a database, long enough to fill a header page...........................................");
	d = e2e.start(tprint("%/bad.db", dir));
	g3: Get;
	g3.run = g.run;
	e2e.submit(d, *g3);
	wait(*g3);
	check(g3.failed && !g3.found && d.error != "", "unreadable database fails jobs");
	e2e.stop(d);
	while !e2e.stopped(d) sleep_milliseconds(1);
	e2e.destroy(d);

	if failed { print("e2e: % failed\n", failed); exit(1); }
	print("e2e: ok\n");
}
