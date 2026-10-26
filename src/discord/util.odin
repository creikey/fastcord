package discord

import "core:crypto"
import "core:mem"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"

Allocator :: mem.Allocator

// ---- time ----

now_ms :: proc() -> i64 {
	return time.time_to_unix_nano(time.now()) / 1e6
}

// ---- uuid v4 (crypto/random based, like the client's uuid module) ----

uuid4 :: proc(allocator := context.allocator) -> string {
	b: [16]byte
	crypto.rand_bytes(b[:])
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	return uuid_format(b, allocator)
}

uuid_format :: proc(b: [16]byte, allocator := context.allocator) -> string {
	HEX := "0123456789abcdef"
	out := make([]byte, 36, allocator)
	j := 0
	for i in 0 ..< 16 {
		if i == 4 || i == 6 || i == 8 || i == 10 {
			out[j] = '-'
			j += 1
		}
		out[j] = HEX[b[i] >> 4]
		out[j + 1] = HEX[b[i] & 15]
		j += 2
	}
	return string(out)
}

uuid_parse :: proc(s: string) -> (b: [16]byte, ok: bool) {
	j := 0
	hv :: proc(c: u8) -> (u8, bool) {
		switch c {
		case '0' ..= '9':
			return c - '0', true
		case 'a' ..= 'f':
			return c - 'a' + 10, true
		case 'A' ..= 'F':
			return c - 'A' + 10, true
		}
		return 0, false
	}
	for i := 0; i < len(s); i += 1 {
		if s[i] == '-' do continue
		if j >= 32 || i + 1 >= len(s) + 1 do return {}, false
		v := hv(s[i]) or_return
		if j % 2 == 0 do b[j / 2] = v << 4
		else do b[j / 2] |= v
		j += 1
	}
	return b, j == 32
}

// ---- snowflakes / nonces ----

// Nonce_Gen reproduces the client's nonce: SnowflakeUtils.fromTimestampWithSequence
// with a sequence that resets whenever Date.now() changes.
Nonce_Gen :: struct {
	mu:      sync.Mutex,
	last_ms: i64,
	seq:     u64,
}

nonce_at :: proc(g: ^Nonce_Gen, ms: i64) -> Snowflake {
	sync.mutex_lock(&g.mu)
	defer sync.mutex_unlock(&g.mu)
	if g.last_ms != ms {
		g.seq = 0
		g.last_ms = ms
	}
	d := ms - DISCORD_EPOCH_MS
	if d < 0 do d = 0
	s := Snowflake(u64(d) << 22 + g.seq)
	g.seq += 1
	return s
}

nonce_next :: proc(g: ^Nonce_Gen) -> Snowflake {
	return nonce_at(g, now_ms())
}

snowflake_from_ms :: proc(ms: i64) -> Snowflake {
	d := ms - DISCORD_EPOCH_MS
	if d <= 0 do return 0
	return Snowflake(u64(d) << 22)
}

snowflake_string :: proc(id: Snowflake, allocator := context.temp_allocator) -> string {
	buf: [24]byte
	return strings.clone(strconv.write_uint(buf[:], u64(id), 10), allocator)
}

parse_snowflake :: proc(s: string) -> Snowflake {
	v, ok := strconv.parse_u64(s, 10)
	return Snowflake(v) if ok else 0
}

// Days since the Discord epoch: the read state `last_viewed` unit.
days_since_epoch :: proc(ms: i64) -> int {
	return int((ms - DISCORD_EPOCH_MS) / 86_400_000)
}

// ---- ordered JSON writer (JSON.stringify layout: no spaces) ----

Json :: struct {
	sb:            strings.Builder,
	comma:         [64]bool,
	depth:         int,
	pending_value: bool, // a key was just written
}

json_init :: proc(w: ^Json, allocator := context.temp_allocator) {
	w^ = {}
	w.sb = strings.builder_make(allocator)
}

json_string :: proc(w: ^Json) -> string {return strings.to_string(w.sb)}

@(private)
json_value_sep :: proc(w: ^Json) {
	if w.pending_value {
		w.pending_value = false
		return
	}
	if w.comma[w.depth] do strings.write_byte(&w.sb, ',')
	w.comma[w.depth] = true
}

json_obj :: proc(w: ^Json) {
	json_value_sep(w)
	strings.write_byte(&w.sb, '{')
	w.depth += 1
	w.comma[w.depth] = false
}

json_obj_end :: proc(w: ^Json) {
	strings.write_byte(&w.sb, '}')
	w.depth -= 1
	w.comma[w.depth] = true
}

json_arr :: proc(w: ^Json) {
	json_value_sep(w)
	strings.write_byte(&w.sb, '[')
	w.depth += 1
	w.comma[w.depth] = false
}

json_arr_end :: proc(w: ^Json) {
	strings.write_byte(&w.sb, ']')
	w.depth -= 1
	w.comma[w.depth] = true
}

// json_key writes `"k":`; the next value is written without a separator.
json_key :: proc(w: ^Json, k: string) {
	if w.comma[w.depth] do strings.write_byte(&w.sb, ',')
	w.comma[w.depth] = true
	json_write_escaped(&w.sb, k)
	strings.write_byte(&w.sb, ':')
	w.pending_value = true
}

json_str :: proc(w: ^Json, s: string) {
	json_value_sep(w)
	json_write_escaped(&w.sb, s)
}

json_int :: proc(w: ^Json, v: i64) {
	json_value_sep(w)
	strings.write_i64(&w.sb, v)
}

json_bool :: proc(w: ^Json, v: bool) {
	json_value_sep(w)
	strings.write_string(&w.sb, "true" if v else "false")
}

json_null :: proc(w: ^Json) {
	json_value_sep(w)
	strings.write_string(&w.sb, "null")
}

// json_raw writes pre-encoded JSON as a value.
json_raw :: proc(w: ^Json, raw: string) {
	json_value_sep(w)
	strings.write_string(&w.sb, raw)
}

json_snowflake :: proc(w: ^Json, id: Snowflake) {
	json_value_sep(w)
	strings.write_byte(&w.sb, '"')
	strings.write_u64(&w.sb, u64(id))
	strings.write_byte(&w.sb, '"')
}

// Key/value shorthands.
json_kstr :: proc(w: ^Json, k, v: string) {json_key(w, k); json_str(w, v)}
json_kint :: proc(w: ^Json, k: string, v: i64) {json_key(w, k); json_int(w, v)}
json_kbool :: proc(w: ^Json, k: string, v: bool) {json_key(w, k); json_bool(w, v)}
json_knull :: proc(w: ^Json, k: string) {json_key(w, k); json_null(w)}
json_ksnow :: proc(w: ^Json, k: string, v: Snowflake) {json_key(w, k); json_snowflake(w, v)}

// JSON.stringify string escaping.
json_write_escaped :: proc(sb: ^strings.Builder, s: string) {
	HEX := "0123456789abcdef"
	strings.write_byte(sb, '"')
	for i in 0 ..< len(s) {
		c := s[i]
		switch c {
		case '"':
			strings.write_string(sb, "\\\"")
		case '\\':
			strings.write_string(sb, "\\\\")
		case '\b':
			strings.write_string(sb, "\\b")
		case '\f':
			strings.write_string(sb, "\\f")
		case '\n':
			strings.write_string(sb, "\\n")
		case '\r':
			strings.write_string(sb, "\\r")
		case '\t':
			strings.write_string(sb, "\\t")
		case:
			if c < 0x20 {
				strings.write_string(sb, "\\u00")
				strings.write_byte(sb, HEX[c >> 4])
				strings.write_byte(sb, HEX[c & 15])
			} else {
				strings.write_byte(sb, c)
			}
		}
	}
	strings.write_byte(sb, '"')
}

// encodeURIComponent.
uri_component :: proc(s: string, allocator := context.temp_allocator) -> string {
	HEX := "0123456789ABCDEF"
	sb := strings.builder_make(allocator)
	for i in 0 ..< len(s) {
		c := s[i]
		switch c {
		case 'A' ..= 'Z', 'a' ..= 'z', '0' ..= '9', '-', '_', '.', '!', '~', '*', '\'', '(', ')':
			strings.write_byte(&sb, c)
		case:
			strings.write_byte(&sb, '%')
			strings.write_byte(&sb, HEX[c >> 4])
			strings.write_byte(&sb, HEX[c & 15])
		}
	}
	return strings.to_string(sb)
}

// Query builds a superagent-style query string: keys in insertion order,
// null/undefined values skipped, values encodeURIComponent'd.
Query :: struct {
	sb:    strings.Builder,
	empty: bool,
}

query_init :: proc(q: ^Query, path: string, allocator := context.temp_allocator) {
	q.sb = strings.builder_make(allocator)
	strings.write_string(&q.sb, path)
	q.empty = true
}

query_add :: proc(q: ^Query, k, v: string) {
	strings.write_byte(&q.sb, '?' if q.empty else '&')
	q.empty = false
	strings.write_string(&q.sb, uri_component(k))
	strings.write_byte(&q.sb, '=')
	strings.write_string(&q.sb, uri_component(v))
}

query_add_int :: proc(q: ^Query, k: string, v: int) {
	buf: [24]byte
	query_add(q, k, strconv.write_int(buf[:], i64(v), 10))
}

query_add_bool :: proc(q: ^Query, k: string, v: bool) {
	query_add(q, k, "true" if v else "false")
}

query_add_snow :: proc(q: ^Query, k: string, v: Snowflake) {
	query_add(q, k, snowflake_string(v))
}

query_string :: proc(q: ^Query) -> string {return strings.to_string(q.sb)}
