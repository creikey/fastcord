// Odin's remove_range: drop a[lo..hi) keeping order (ranges may overlap, so copy forward by element).
remove_range :: (a: *[..]$T, lo: int, hi: int) {
	for i: hi..a.count-1 { a.*[lo + i - hi] = a.*[i]; }
	a.count -= hi - lo;
}

// run_cmd: run a command, pass its stderr through, return success and stdout.
run_cmd :: (cmd: []string) -> bool, string {
	st, out, err, e := os.process_exec(.{command = cmd});
	if len(err) { fmt.eprint(as_string(err)); }
	return e == null && st.success, as_string(out);
}

must :: (ok: bool) { if !ok { os.exit(1); } }

// diff_count: the count on trafficdiff's last line ("traffic matches" is 0).
diff_count :: (out: string) -> string {
	line := strings.trim_right_space(out);
	line = sub_from(line, strings.last_index_byte(line, #char "\n") + 1);
	if line == "traffic matches" { return "0"; }
	i := strings.index_byte(line, #char " ");
	return ifx i < 0 then line else sub(line, 0, i);
}
