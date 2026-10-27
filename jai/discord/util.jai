Allocator :: Allocator;

// ---- time ----

now_ms :: () -> s64 {
	return time.time_to_unix_nano(time.now()) / 1000000;
}

// now_ms_f: unix ms with sub-millisecond precision (traffic tooling ordering).
now_ms_f :: () -> float64 {
	return cast(float64)(time.time_to_unix_nano(time.now())) / 1000000;
}

// ---- uuid v4 (crypto/random based, like the client's uuid module) ----

uuid4 :: (allocator := context.allocator) -> string {
	b: [16]u8;
	crypto.rand_bytes(view(b));
	b[6] = (b[6] & 0x0f) | 0x40;
	b[8] = (b[8] & 0x3f) | 0x80;
	return uuid_format(b, allocator);
}

uuid_format :: (b: [16]u8, allocator := context.allocator) -> string {
	HEX := "0123456789abcdef";
	out := make_slice(u8, 36, allocator);
	j := 0;
	for i: 0..15 {
		if i == 4 || i == 6 || i == 8 || i == 10 {
			at(*out, j).* = #char "-";
			j += 1;
		}
		at(*out, j).* = HEX[b[i] >> 4];
		at(*out, j + 1).* = HEX[b[i] & 15];
		j += 2;
	}
	return as_string(out);
}

uuid_parse :: (s: string) -> [16]u8, bool {
	b: [16]u8;
	ok: bool;
	j := 0;
	hv :: (c: u8) -> u8, bool {
		if (c >= #char "0" && c <= #char "9") {
			return c - #char "0", true;
		} else if (c >= #char "a" && c <= #char "f") {
			return c - #char "a" + 10, true;
		} else if (c >= #char "A" && c <= #char "F") {
			return c - #char "A" + 10, true;
		}
		return 0, false;
	}
	for i: 0..len(s)-1 {
		if s[i] == #char "-" { continue; }
		if j >= 32 || i + 1 >= len(s) + 1 { return .[], false; }
		v, __e2 := hv(s[i]); if failed(__e2) return b, __e2;
		if j % 2 == 0 { b[j / 2] = v << 4; } else { b[j / 2] |= v; }
		j += 1;
	}
	return b, j == 32;
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
	d := ms - DISCORD_EPOCH_MS;
	if d < 0 { d = 0; }
	s := cast(Snowflake)(((cast(u64)(d)) << 22) + g.seq);
	g.seq += 1;
	return s;
}

nonce_next :: (g: *Nonce_Gen) -> Snowflake {
	return nonce_at(g, now_ms());
}

snowflake_from_ms :: (ms: s64) -> Snowflake {
	d := ms - DISCORD_EPOCH_MS;
	if d <= 0 { return 0; }
	return cast(Snowflake)((cast(u64)(d)) << 22);
}

snowflake_string :: (id: Snowflake, allocator := temp) -> string {
	buf: [24]u8;
	return clone(strconv.write_uint(view(buf), cast(u64)(id), 10), allocator);
}

parse_snowflake :: (s: string) -> Snowflake {
	v, ok := strconv.parse_u64(s, 10);
	return ifx ok then cast(Snowflake)(v) else 0;
}

// Days since the Discord epoch: the read state `last_viewed` unit.
days_since_epoch :: (ms: s64) -> int {
	return cast(int)((ms - DISCORD_EPOCH_MS) / 86_400_000);
}

// ---- ordered JSON writer (JSON.stringify layout: no spaces) ----

Json :: struct {
	sb: strings.Builder;
	comma: [64]bool;
	depth: int;
	pending_value: bool; // a key was just written
}

json_init :: (w: *Json, allocator := temp) {
	w.* = .{};
	w.sb = strings.builder_make(allocator);
}

json_string :: (w: *Json) -> string {return strings.to_string(w.sb);}
#scope_module

json_value_sep :: (w: *Json) {
	if w.pending_value {
		w.pending_value = false;
		return;
	}
	if w.comma[w.depth] { strings.write_byte(*w.sb, #char ","); }
	w.comma[w.depth] = true;
}
#scope_export

json_obj :: (w: *Json) {
	json_value_sep(w);
	strings.write_byte(*w.sb, #char "{");
	w.depth += 1;
	w.comma[w.depth] = false;
}

json_obj_end :: (w: *Json) {
	strings.write_byte(*w.sb, #char "}");
	w.depth -= 1;
	w.comma[w.depth] = true;
}

json_arr :: (w: *Json) {
	json_value_sep(w);
	strings.write_byte(*w.sb, #char "[");
	w.depth += 1;
	w.comma[w.depth] = false;
}

json_arr_end :: (w: *Json) {
	strings.write_byte(*w.sb, #char "]");
	w.depth -= 1;
	w.comma[w.depth] = true;
}

// json_key writes `"k":`; the next value is written without a separator.
json_key :: (w: *Json, k: string) {
	if w.comma[w.depth] { strings.write_byte(*w.sb, #char ","); }
	w.comma[w.depth] = true;
	json_write_escaped(*w.sb, k);
	strings.write_byte(*w.sb, #char ":");
	w.pending_value = true;
}

json_str :: (w: *Json, s: string) {
	json_value_sep(w);
	json_write_escaped(*w.sb, s);
}

json_int :: (w: *Json, v: s64) {
	json_value_sep(w);
	strings.write_i64(*w.sb, v);
}

json_bool :: (w: *Json, v: bool) {
	json_value_sep(w);
	strings.write_string(*w.sb, ifx v then "true" else "false");
}

json_null :: (w: *Json) {
	json_value_sep(w);
	strings.write_string(*w.sb, "null");
}

// json_raw writes pre-encoded JSON as a value.
json_raw :: (w: *Json, raw: string) {
	json_value_sep(w);
	strings.write_string(*w.sb, raw);
}

json_snowflake :: (w: *Json, id: Snowflake) {
	json_value_sep(w);
	strings.write_byte(*w.sb, 34);
	strings.write_u64(*w.sb, cast(u64)(id));
	strings.write_byte(*w.sb, 34);
}

// Key/value shorthands.
json_kstr :: (w: *Json, k: string, v: string) {json_key(w, k); json_str(w, v);}
json_kint :: (w: *Json, k: string, v: s64) {json_key(w, k); json_int(w, v);}
json_kbool :: (w: *Json, k: string, v: bool) {json_key(w, k); json_bool(w, v);}
json_knull :: (w: *Json, k: string) {json_key(w, k); json_null(w);}
json_ksnow :: (w: *Json, k: string, v: Snowflake) {json_key(w, k); json_snowflake(w, v);}

// JSON.stringify string escaping.
json_write_escaped :: (sb: *strings.Builder, s: string) {
	HEX := "0123456789abcdef";
	strings.write_byte(sb, 34);
	for i: 0..len(s)-1 {
		c := s[i];
		if c == 34 {
			strings.write_string(sb, "\\\"");
		} else if c == 92 {
			strings.write_string(sb, "\\\\");
		} else if c == 8 {
			strings.write_string(sb, "\\b");
		} else if c == 12 {
			strings.write_string(sb, "\\f");
		} else if c == 10 {
			strings.write_string(sb, "\\n");
		} else if c == 13 {
			strings.write_string(sb, "\\r");
		} else if c == 9 {
			strings.write_string(sb, "\\t");
		} else {
			if c < 0x20 {
				strings.write_string(sb, "\\u00");
				strings.write_byte(sb, HEX[c >> 4]);
				strings.write_byte(sb, HEX[c & 15]);
			} else {
				strings.write_byte(sb, c);
			}
		}
	}
	strings.write_byte(sb, 34);
}

// encodeURIComponent.
uri_component :: (s: string, allocator := temp) -> string {
	HEX := "0123456789ABCDEF";
	sb := strings.builder_make(allocator);
	for i: 0..len(s)-1 {
		c := s[i];
		if (c >= #char "A" && c <= #char "Z") || (c >= #char "a" && c <= #char "z") || (c >= #char "0" && c <= #char "9") || c == #char "-" || c == #char "_" || c == #char "." || c == #char "!" || c == #char "~" || c == #char "*" || c == #char "'" || c == #char "(" || c == #char ")" {
			strings.write_byte(*sb, c);
		} else {
			strings.write_byte(*sb, #char "%");
			strings.write_byte(*sb, HEX[c >> 4]);
			strings.write_byte(*sb, HEX[c & 15]);
		}
	}
	return strings.to_string(sb);
}

// Query builds a superagent-style query string: keys in insertion order,
// null/undefined values skipped, values encodeURIComponent'd.
Query :: struct {
	sb: strings.Builder;
	empty: bool;
}

query_init :: (q: *Query, path: string, allocator := temp) {
	q.sb = strings.builder_make(allocator);
	strings.write_string(*q.sb, path);
	q.empty = true;
}

query_add :: (q: *Query, k: string, v: string) {
	strings.write_byte(*q.sb, ifx q.empty then #char "?" else #char "&");
	q.empty = false;
	strings.write_string(*q.sb, uri_component(k));
	strings.write_byte(*q.sb, #char "=");
	strings.write_string(*q.sb, uri_component(v));
}

query_add_int :: (q: *Query, k: string, v: int) {
	buf: [24]u8;
	query_add(q, k, strconv.write_int(view(buf), cast(s64)(v), 10));
}

query_add_bool :: (q: *Query, k: string, v: bool) {
	query_add(q, k, ifx v then "true" else "false");
}

query_add_snow :: (q: *Query, k: string, v: Snowflake) {
	query_add(q, k, snowflake_string(v));
}

query_string :: (q: *Query) -> string {return strings.to_string(q.sb);}

