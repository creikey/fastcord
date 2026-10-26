package scrub

import "core:fmt"
import "core:slice"
import "core:strconv"
import "core:strings"
import "fc:etf"

// Placeholder state for one fixture: the same original always maps to the
// same placeholder, numbered in order of first appearance.
Ctx :: struct {
	allow:        map[string]bool, // snowflakes kept verbatim (test accounts, test guild, ...)
	others:       map[string]bool, // user ids of people who are not test accounts
	run_start_ms: i64, // unix ms; snowflakes created after this are <new:N>
	ph:           map[string]string, // "kind\x00original" -> placeholder
	counts:       map[string]int,
}

DISCORD_EPOCH :: 1420070400000

placeholder :: proc(c: ^Ctx, kind, original: string) -> string {
	key := fmt.tprintf("%s\x00%s", kind, original)
	if p, ok := c.ph[key]; ok do return p
	c.counts[kind] += 1
	p := fmt.aprintf("<%s:%d>", kind, c.counts[kind])
	c.ph[strings.clone(key)] = p
	return p
}

// Keys whose whole value is a secret or per-run identifier.
@(private)
key_rule :: proc(key: string) -> (kind: string, numbered: bool, ok: bool) {
	if key == "client_heartbeat_session_id" || key == "heartbeat_session_id" do return fmt.tprintf("id:%s", key), true, true
	if strings.has_suffix(key, "session_id") || strings.has_suffix(key, "session_id_hash") || key == "id_hash" do return "sid", true, true
	switch key {
	case "token", "authorization", "auth_token", "captcha_key", "password", "new_password", "ticket", "mfa_token", "access_token", "refresh_token":
		return "token", false, true
	case "email", "email_address":
		return "email", false, true
	case "phone", "phone_number":
		return "phone", false, true
	case "nonce", "enforce_nonce":
		return "nonce", true, true
	case "session_id", "client_session_id", "static_client_session_id", "auth_session_id_hash", "media_session_id":
		return "sid", true, true
	case "analytics_token", "qos_token", "fingerprint", "installation_id", "launch_signature", "client_launch_id",
	     "client_heartbeat_session_id", "heartbeat_session_id", "device_vendor_id", "client_ad_session_id":
		return fmt.tprintf("id:%s", key), true, true
	case "ip", "ip_address", "remote_ip":
		return "ip", false, true
	case "country_code", "subdivision_code":
		return "geo", false, true
	}
	return "", false, false
}

// Header names with fixed scrubbing.
header_rule :: proc(c: ^Ctx, name: string, value: string) -> (etf.Value, bool) {
	lname := strings.to_lower(name, context.temp_allocator)
	switch lname {
	case "authorization":
		return string("<token>"), true
	case "cookie", "set-cookie":
		return string("<cookie>"), true
	case "x-fingerprint":
		return placeholder(c, "id:fingerprint", value), true
	case "x-installation-id":
		return placeholder(c, "id:installation_id", value), true
	case "x-captcha-key", "x-captcha-rqtoken", "x-captcha-session-id":
		return string("<token>"), true
	case "x-super-properties", "x-context-properties":
		if decoded, ok := decode_b64_json(value); ok {
			m := etf.Map(make([]etf.Pair, 1))
			m[0] = {key = string("$b64json"), value = scrub_value(c, decoded, "")}
			return m, true
		}
	}
	return nil, false
}

@(private)
decode_b64_json :: proc(s: string) -> (etf.Value, bool) {
	raw, err := b64_decode(s)
	if !err do return nil, false
	v, jerr := etf.from_json(string(raw))
	return v, jerr == .None
}

is_snowflake_digits :: proc(s: string) -> bool {
	if len(s) < 17 || len(s) > 20 do return false
	for ch in transmute([]byte)s do if ch < '0' || ch > '9' do return false
	return true
}

// snowflake_ms returns the creation time of a plausible snowflake (0 if implausible).
snowflake_ms :: proc(s: string) -> i64 {
	x, ok := strconv.parse_u64_of_base(s, 10)
	if !ok do return 0
	ms := i64(x >> 22) + DISCORD_EPOCH
	if ms < 1430000000000 || ms > 2200000000000 do return 0
	return ms
}

// classify_snowflake returns the replacement for a snowflake string ("" = keep).
classify_snowflake :: proc(c: ^Ctx, s: string) -> string {
	if c.allow[s] do return ""
	if c.others[s] do return placeholder(c, "user", s)
	ms := snowflake_ms(s)
	if ms == 0 do return ""
	if c.run_start_ms > 0 && ms >= c.run_start_ms - 120_000 do return placeholder(c, "new", s)
	return ""
}

@(private)
is_b64url :: proc(ch: u8) -> bool {
	return (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == '-' || ch == '_'
}

@(private)
is_hex :: proc(ch: u8) -> bool {return (ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f') || (ch >= 'A' && ch <= 'F')}

// token_at: Discord user tokens look like <24-28>.<6>.<27-40> base64url segments.
token_at :: proc(s: string, i: int) -> int {
	if i > 0 && is_b64url(s[i - 1]) do return 0
	seg := [3][2]int{{24, 30}, {6, 7}, {25, 45}}
	j := i
	for k in 0 ..< 3 {
		n := 0
		for j < len(s) && is_b64url(s[j]) {
			j += 1
			n += 1
		}
		if n < seg[k][0] || n > seg[k][1] do return 0
		if k < 2 {
			if j >= len(s) || s[j] != '.' do return 0
			j += 1
		}
	}
	return j - i
}

@(private)
uuid_at :: proc(s: string, i: int) -> bool {
	if i + 36 > len(s) do return false
	if i > 0 && is_hex(s[i - 1]) do return false
	if i + 36 < len(s) && is_hex(s[i + 36]) do return false
	for k in 0 ..< 36 {
		ch := s[i + k]
		if k == 8 || k == 13 || k == 18 || k == 23 {
			if ch != '-' do return false
		} else if !is_hex(ch) {
			return false
		}
	}
	return true
}

@(private)
email_span :: proc(s: string, at: int) -> (start, end: int, ok: bool) {
	start = at
	for start > 0 && (is_b64url(s[start - 1]) || s[start - 1] == '.' || s[start - 1] == '+' || s[start - 1] == '%') do start -= 1
	end = at + 1
	dot := false
	for end < len(s) && (is_b64url(s[end]) || s[end] == '.') {
		if s[end] == '.' do dot = true
		end += 1
	}
	for end > at + 1 && s[end - 1] == '.' do end -= 1
	return start, end, start < at && dot && end > at + 3
}

// scrub_text replaces tokens, emails, UUIDs and snowflakes inside free text.
scrub_text :: proc(c: ^Ctx, s: string) -> string {
	sb := strings.builder_make()
	i := 0
	for i < len(s) {
		if n := token_at(s, i); n > 0 {
			strings.write_string(&sb, "<token>")
			i += n
			continue
		}
		if uuid_at(s, i) {
			strings.write_string(&sb, placeholder(c, "uuid", strings.to_lower(s[i:i + 36], context.temp_allocator)))
			i += 36
			continue
		}
		if s[i] == '@' {
			if st, en, ok := email_span(s, i); ok && len(sb.buf) >= i - st {
				// drop the local part already written, then the placeholder
				resize(&sb.buf, len(sb.buf) - (i - st))
				strings.write_string(&sb, "<email>")
				i = en
				continue
			}
		}
		if s[i] >= '0' && s[i] <= '9' && (i == 0 || s[i - 1] < '0' || s[i - 1] > '9') {
			j := i
			for j < len(s) && s[j] >= '0' && s[j] <= '9' do j += 1
			if is_snowflake_digits(s[i:j]) {
				if r := classify_snowflake(c, s[i:j]); r != "" {
					strings.write_string(&sb, r)
					i = j
					continue
				}
			}
			strings.write_string(&sb, s[i:j])
			i = j
			continue
		}
		strings.write_byte(&sb, s[i])
		i += 1
	}
	return strings.to_string(sb)
}

@(private)
user_fields :: proc(key: string) -> bool {
	switch key {
	case "username", "global_name", "display_name", "nick", "bio", "pronouns", "avatar", "banner", "avatar_decoration_data", "primary_guild", "collectibles", "clan", "display_name_styles":
		return true
	}
	return false
}

@(private)
map_str :: proc(m: etf.Map, key: string) -> string {
	v, _ := etf.map_get(m, key)
	#partial switch x in v {
	case string:
		return x
	case i64:
		return fmt.tprintf("%d", x)
	}
	return ""
}

// scrub_value deep-copies v with every rule applied. key is the map key v sits under.
scrub_value :: proc(c: ^Ctx, v: etf.Value, key: string) -> etf.Value {
	if kind, numbered, ok := key_rule(key); ok {
		#partial switch x in v {
		case nil, bool:
			return v
		case etf.Map, etf.List:
		// structured value under a secret-looking key: recurse instead
		case:
			if !numbered do return fmt.aprintf("<%s>", kind)
			return placeholder(c, kind, fmt.tprintf("%v", x))
		}
	}
	switch x in v {
	case nil, bool, f64:
		return v
	case etf.Big:
		return etf.Big{negative = x.negative, digits = slice.clone(x.digits)}
	case etf.Atom:
		return scrub_text(c, string(x))
	case etf.Charlist:
		return etf.Charlist(strings.clone(string(x)))
	case i64:
		s := fmt.tprintf("%d", x)
		if is_snowflake_digits(s) {
			if r := classify_snowflake(c, s); r != "" do return r
		}
		return v
	case string:
		return scrub_text(c, x)
	case etf.List:
		out := make([]etf.Value, len(x))
		for e, i in x do out[i] = scrub_value(c, e, key)
		return etf.List(out)
	case etf.Tuple:
		out := make([]etf.Value, len(x))
		for e, i in x do out[i] = scrub_value(c, e, key)
		return etf.Tuple(out)
	case etf.Map:
		// people who are not test accounts: no names/avatars/bios in fixtures
		foreign_user := false
		if _, has := etf.map_get(x, "username"); has {
			if id := map_str(x, "id"); id != "" && c.others[id] do foreign_user = true
		}
		foreign_author := false
		if a, has := etf.map_get(x, "author"); has {
			if am, is_map := a.(etf.Map); is_map {
				if id := map_str(am, "id"); id != "" && c.others[id] do foreign_author = true
			}
		}
		out := make([]etf.Pair, len(x))
		for p, i in x {
			k, _ := p.key.(string)
			out[i].key = scrub_value(c, p.key, "") // keys can be ids (e.g. guild_versions)
			switch {
			case foreign_user && user_fields(k):
				out[i].value = placeholder(c, "user", map_str(x, "id")) if k == "username" || k == "global_name" || k == "display_name" || k == "nick" else nil
			case foreign_author && (k == "content" || k == "attachments" || k == "embeds" || k == "components"):
				out[i].value = string("<content>") if k == "content" else etf.List(nil)
			case:
				out[i].value = scrub_value(c, p.value, k)
			}
		}
		return etf.Map(out)
	}
	return v
}

// collect_foreign records ids of user objects that aren't test accounts.
collect_foreign :: proc(c: ^Ctx, v: etf.Value) {
	#partial switch x in v {
	case etf.List:
		for e in x do collect_foreign(c, e)
	case etf.Map:
		if _, has := etf.map_get(x, "username"); has {
			if id := map_str(x, "id"); is_snowflake_digits(id) && !c.allow[id] do c.others[strings.clone(id)] = true
		}
		for p in x do collect_foreign(c, p.value)
	}
}
