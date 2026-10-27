// Test harness for the TESTS build: T, expect*, and run_tests over every `<name> :: (t: *T) {` in
// replay_test.jai.

T :: struct { name: string; failed: bool; log: String_Builder; }

expect :: (t: *T, ok: bool, msg := "", loc := #caller_location) -> bool {
	if !ok { t.failed = true; print_to_builder(*t.log, "  %:%: expectation failed %\n", loc.fully_pathed_filename, loc.line_number, msg); }
	return ok;
}

expectf :: (t: *T, ok: bool, format: string, args: ..Any, loc := #caller_location) -> bool {
	if !ok {
		t.failed = true;
		print_to_builder(*t.log, "  %:%: ", loc.fully_pathed_filename, loc.line_number);
		print_to_builder(*t.log, format, ..args);
		append(*t.log, "\n");
	}
	return ok;
}

expect_value :: (t: *T, got: $A, want: $B, loc := #caller_location) -> bool {
	ok := got == cast(A) want;
	if !ok { t.failed = true; print_to_builder(*t.log, "  %:%: expected %, got %\n", loc.fully_pathed_filename, loc.line_number, want, got); }
	return ok;
}

Test :: struct { name: string; proc: (t: *T); }
ALL_TESTS :: #insert #run test_table(tprint("%replay_test.jai", #filepath));

#scope_file
STRING_TMP :: #import "String"; slice :: STRING_TMP.slice; // TEMP until module.jai drops fc_slice

test_table :: (file: string) -> string {
	names: [..]string;
	for line: split(read_entire_file(file), "\n") {
		e := find_index_from_left(line, " :: (t: *T) {");
		if e > 0 && !contains(slice(line, 0, e), " ") array_add(*names, slice(line, 0, e));
	}
	quick_sort(names, compare_strings); // by name
	sb: String_Builder;
	append(*sb, "Test.[");
	for names print_to_builder(*sb, ".{\"%1\", %1},", it);
	append(*sb, "];");
	return builder_to_string(*sb);
}
#scope_export

// run_tests runs every test whose name contains one of `filters` (all when empty), by name and `jobs`
// at a time, prints PASS / FAIL per test and returns the number of failures.
run_tests :: (filters: []string, jobs := 0) -> int {
	State :: struct { mu: locks.Mutex; next: int; failed: int; filters: []string; }
	st := State.{filters = filters};
	worker :: (st: *State) {
		while true {
			locks.lock(*st.mu);
			i := st.next;
			st.next += 1;
			locks.unlock(*st.mu);
			if i >= ALL_TESTS.count break;
			test := ALL_TESTS[i];
			if st.filters {
				hit := false;
				for st.filters if contains(test.name, it) hit = true;
				if !hit continue;
			}
			t := T.{name = test.name};
			t.log.allocator = context.default_allocator; // the log must not depend on temp
			start := current_time_monotonic();
			test.proc(*t);
			ms := to_milliseconds(current_time_monotonic() - start);
			locks.lock(*st.mu);
			if t.failed st.failed += 1;
			print("% % (% ms)\n", ifx t.failed then "FAIL" else "PASS", test.name, ms);
			if t.failed write_builder(*t.log);
			locks.unlock(*st.mu);
			free_buffers(*t.log);
			reset_temporary_storage();
		}
	}
	threads: [..]*Thread;
	if jobs <= 0 jobs = get_number_of_processors(); // one per core
	for 1..jobs array_add(*threads, spawn(*st, worker));
	for threads locks.join(it);
	array_free(threads);
	return st.failed;
}
