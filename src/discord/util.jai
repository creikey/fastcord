// ---- threads ----

// spawn runs proc(data) on a new thread (its own temporary storage); locks.join ends and frees it.
spawn :: (data: $D, proc: (D)) -> *Thread {
	Spawned :: struct { #as thread: Thread; arg: D; run: (D); }
	s := New(Spawned);
	s.arg, s.run = data, proc;
	thread_init(s, (t: *Thread) -> s64 { s := cast(*Spawned) t; s.run(s.arg); return 0; });
	thread_start(s);
	return s;
}

// pool_allocator: a Flat_Pool owned by one thread at a time (a job's strings, a result's or a gateway
// payload's tree); fini frees it.
pool_allocator :: (p: *Flat_Pool) -> Allocator { return .{flat_pool_allocator_proc, p}; }

// ---- time ----

// 1970-01-01 in Apollo time (14182941 s after the Apollo epoch). A literal: Basic's calendar math uses x64
// #asm, which the ARM compiler can't run at compile time when building the x64 half of a release.
UNIX_EPOCH :: Apollo_Time.{low = 15841551391064358912, high = 768};

now_ms :: () -> s64 { return to_milliseconds(current_time_consensus() - UNIX_EPOCH); }

// now_ms_f: unix ms with sub-millisecond precision (traffic tooling ordering).
now_ms_f :: () -> float64 { return cast(float64) to_nanoseconds(current_time_consensus() - UNIX_EPOCH) / 1_000_000; }

// mono_ms: monotonic milliseconds, for timeouts and durations.
mono_ms :: () -> s64 { return to_milliseconds(current_time_monotonic()); }

// ---- uuid v4 (crypto/random based, like the client's uuid module) ----

uuid4 :: () -> string {
	b: [16]u8;
	crypto.random_bytes(b);
	b[6] = (b[6] & 0x0f) | 0x40;
	b[8] = (b[8] & 0x3f) | 0x80;
	return uuid_format(b);
}

uuid_format :: (b: [16]u8) -> string {
	HEX :: "0123456789abcdef";
	out := alloc_string(36);
	j := 0;
	for b {
		if it_index == 4 || it_index == 6 || it_index == 8 || it_index == 10 {
			out[j] = #char "-";
			j += 1;
		}
		out[j] = HEX[it >> 4];
		out[j + 1] = HEX[it & 15];
		j += 2;
	}
	return out;
}

uuid_parse :: (s: string) -> [16]u8, bool {
	b: [16]u8;
	j := 0;
	for c: cast([]u8) s {
		if c == #char "-" continue;
		v := hex_digit(c);
		if j >= 32 || v < 0 return b, false;
		if j % 2 == 0 b[j / 2] = cast(u8) (v << 4); else b[j / 2] |= cast(u8) v;
		j += 1;
	}
	return b, j == 32;
}

hex_digit :: (c: u8) -> int {
	if c >= #char "0" && c <= #char "9" return c - #char "0";
	if c >= #char "a" && c <= #char "f" return c - #char "a" + 10;
	if c >= #char "A" && c <= #char "F" return c - #char "A" + 10;
	return -1;
}

// ---- snowflakes / nonces ----

// Nonce_Gen reproduces the client's nonce: SnowflakeUtils.fromTimestampWithSequence
// with a sequence that resets whenever Date.now() changes.
Nonce_Gen :: struct {
	mu: locks.Mutex;
	last_ms: s64;
	seq: u64;
}

nonce_at :: (g: *Nonce_Gen, ms: s64) -> Snowflake {
	locks.lock(*g.mu);
	defer locks.unlock(*g.mu);
	if g.last_ms != ms {
		g.seq = 0;
		g.last_ms = ms;
	}
	s := ((cast(u64) max(ms - DISCORD_EPOCH_MS, 0)) << 22) + g.seq;
	g.seq += 1;
	return s;
}

nonce_next :: (g: *Nonce_Gen) -> Snowflake { return nonce_at(g, now_ms()); }

snowflake_from_ms :: (ms: s64) -> Snowflake {
	d := ms - DISCORD_EPOCH_MS;
	return ifx d <= 0 then 0 else (cast(u64) d) << 22;
}

snowflake_string :: (id: Snowflake, allocator := temp) -> string { return sprint("%", id,, allocator); }

// parse_snowflake: a decimal id (0 if s is not one).
parse_snowflake :: (s: string) -> Snowflake {
	v, ok := parse_u64(s);
	return ifx ok then v else 0;
}

// parse_u64 / parse_s64: all of s as a decimal number.
parse_u64 :: (s: string) -> u64, bool {
	if s && (s[0] < #char "0" || s[0] > #char "9") return 0, false; // no sign or spaces
	v, ok, rest := string_to_int(s, 10, u64);
	return v, ok && !rest;
}

parse_s64 :: (s: string) -> s64, bool {
	if s && s[0] == #char " " return 0, false;
	v, ok, rest := string_to_int(s, 10, s64);
	return v, ok && !rest;
}

// Days since the Discord epoch: the read state `last_viewed` unit.
days_since_epoch :: (ms: s64) -> int { return (ms - DISCORD_EPOCH_MS) / 86_400_000; }

// Snowflake_Pair_Set: a set of (guild, user) pairs.
Snowflake_Pair_Set :: Table([2]Snowflake, bool, given_hash_function = sf_pair_hash, given_compare_function = sf_pair_eq);
sf_pair_hash :: (k: [2]Snowflake) -> u32 { return get_hash(k[0], get_hash(k[1])); }
sf_pair_eq :: (a: [2]Snowflake, b: [2]Snowflake) -> bool { return a[0] == b[0] && a[1] == b[1]; }

// ---- ordered JSON writer (JSON.stringify layout: no spaces) ----

Json :: struct {
	buf: [..]u8;
	comma: [64]bool;
	depth: int;
	pending_value: bool; // a key was just written
}

json_init :: (w: *Json, allocator := temp) {
	w.* = .{};
	w.buf.allocator = allocator;
}

// json_string: the text so far (a view of the writer's buffer).
json_string :: (w: *Json) -> string { return cast(string) w.buf; }

json_value_sep :: (w: *Json) {
	if w.pending_value {
		w.pending_value = false;
		return;
	}
	if w.comma[w.depth] array_add(*w.buf, #char ",");
	w.comma[w.depth] = true;
}

json_open :: (w: *Json, c: u8) {
	json_value_sep(w);
	array_add(*w.buf, c);
	w.depth += 1;
	w.comma[w.depth] = false;
}

json_close :: (w: *Json, c: u8) {
	array_add(*w.buf, c);
	w.depth -= 1;
	w.comma[w.depth] = true;
}

json_obj :: (w: *Json) { json_open(w, #char "{"); }
json_obj_end :: (w: *Json) { json_close(w, #char "}"); }
json_arr :: (w: *Json) { json_open(w, #char "["); }
json_arr_end :: (w: *Json) { json_close(w, #char "]"); }

// json_key writes `"k":`; the next value is written without a separator.
json_key :: (w: *Json, k: string) {
	if w.comma[w.depth] array_add(*w.buf, #char ",");
	w.comma[w.depth] = true;
	json_write_escaped(*w.buf, k);
	array_add(*w.buf, #char ":");
	w.pending_value = true;
}

json_str :: (w: *Json, s: string) {
	json_value_sep(w);
	json_write_escaped(*w.buf, s);
}

// json_raw writes pre-encoded JSON as a value.
json_raw :: (w: *Json, raw: string) {
	json_value_sep(w);
	append_string(*w.buf, raw);
}

json_int :: (w: *Json, v: s64) { json_raw(w, tprint("%", v)); }
json_bool :: (w: *Json, v: bool) { json_raw(w, ifx v then "true" else "false"); }
json_null :: (w: *Json) { json_raw(w, "null"); }
json_snowflake :: (w: *Json, id: Snowflake) { json_raw(w, tprint("\"%\"", id)); }

// Key/value shorthands.
json_kstr :: (w: *Json, k: string, v: string) { json_key(w, k); json_str(w, v); }
json_kint :: (w: *Json, k: string, v: s64) { json_key(w, k); json_int(w, v); }
json_kbool :: (w: *Json, k: string, v: bool) { json_key(w, k); json_bool(w, v); }
json_knull :: (w: *Json, k: string) { json_key(w, k); json_null(w); }
json_ksnow :: (w: *Json, k: string, v: Snowflake) { json_key(w, k); json_snowflake(w, v); }

append_string :: (buf: *[..]u8, s: string) { array_add(buf, ..cast([]u8) s); }

// JSON.stringify string escaping.
json_write_escaped :: (buf: *[..]u8, s: string) {
	HEX :: "0123456789abcdef";
	array_add(buf, #char "\"");
	for c: cast([]u8) s {
		if c == {
			case #char "\""; append_string(buf, "\\\"");
			case #char "\\"; append_string(buf, "\\\\");
			case 8;  append_string(buf, "\\b");
			case 12; append_string(buf, "\\f");
			case 10; append_string(buf, "\\n");
			case 13; append_string(buf, "\\r");
			case 9;  append_string(buf, "\\t");
			case;
				if c < 0x20 {
					append_string(buf, "\\u00");
					array_add(buf, HEX[c >> 4], HEX[c & 15]);
				} else {
					array_add(buf, c);
				}
		}
	}
	array_add(buf, #char "\"");
}

// encodeURIComponent.
uri_component :: (s: string, allocator := temp) -> string {
	HEX :: "0123456789ABCDEF";
	out: [..]u8;
	out.allocator = allocator;
	for c: cast([]u8) s {
		if is_alnum(c) || contains("-.!~*'()", c) {
			array_add(*out, c);
		} else {
			array_add(*out, #char "%", HEX[c >> 4], HEX[c & 15]);
		}
	}
	return cast(string) out;
}

// Query builds a superagent-style query string: keys in insertion order,
// null/undefined values skipped, values encodeURIComponent'd.
Query :: struct {
	buf: [..]u8;
	empty := true;
}

query_init :: (q: *Query, path: string, allocator := temp) {
	q.* = .{};
	q.buf.allocator = allocator;
	append_string(*q.buf, path);
}

query_add :: (q: *Query, k: string, v: string) {
	array_add(*q.buf, cast(u8) ifx q.empty then #char "?" else #char "&");
	q.empty = false;
	append_string(*q.buf, uri_component(k));
	array_add(*q.buf, #char "=");
	append_string(*q.buf, uri_component(v));
}

query_add_int :: (q: *Query, k: string, v: int) { query_add(q, k, tprint("%", v)); }
query_add_bool :: (q: *Query, k: string, v: bool) { query_add(q, k, ifx v then "true" else "false"); }
query_add_snow :: (q: *Query, k: string, v: Snowflake) { query_add(q, k, tprint("%", v)); }

query_string :: (q: *Query) -> string { return cast(string) q.buf; }
