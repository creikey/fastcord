// Placeholder state for one fixture: the same original always maps to the
// same placeholder, numbered in order of first appearance.
Ctx :: struct {
	allow: Map(string, bool); // snowflakes kept verbatim (test accounts, test guild, ...)
	others: Map(string, bool); // user ids of people who are not test accounts
	run_start_ms: s64; // unix ms; snowflakes created after this are <new:N>
	ph: Map(string, string); // "kind\x00original" -> placeholder
	counts: Map(string, int);
}

DISCORD_EPOCH :: 1420070400000;

placeholder :: (c: *Ctx, kind: string, original: string) -> string {
	key := fmt.tprintf("%s\x00%s", kind, original);
	{ p, ok := map_find(c.ph, key);
	if ok { return p; } }
	at(*c.counts, kind).* += 1;
	p := fmt.aprintf("<%s:%d>", kind, get(c.counts, kind));
	at(*c.ph, clone(key)).* = p;
	return p;
}
#scope_module

// Keys whose whole value is a secret or per-run identifier.
key_rule :: (key: string) -> string, bool, bool {
	kind: string;
	numbered: bool;
	ok: bool;
	if key == "client_heartbeat_session_id" || key == "heartbeat_session_id" { return fmt.tprintf("id:%s", key), true, true; }
	if strings.has_suffix(key, "session_id") || strings.has_suffix(key, "session_id_hash") || key == "id_hash" { return "sid", true, true; }
	if key == {
	case "token"; #through; case "authorization"; #through; case "auth_token"; #through; case "captcha_key"; #through; case "password"; #through; case "new_password"; #through; case "ticket"; #through; case "mfa_token"; #through; case "access_token"; #through; case "refresh_token";
		return "token", false, true;
	case "email"; #through; case "email_address";
		return "email", false, true;
	case "phone"; #through; case "phone_number";
		return "phone", false, true;
	case "nonce"; #through; case "enforce_nonce";
		return "nonce", true, true;
	case "session_id"; #through; case "client_session_id"; #through; case "static_client_session_id"; #through; case "auth_session_id_hash"; #through; case "media_session_id";
		return "sid", true, true;
	case "analytics_token"; #through; case "qos_token"; #through; case "fingerprint"; #through; case "installation_id"; #through; case "launch_signature"; #through; case "client_launch_id"; #through; case "client_heartbeat_session_id"; #through; case "heartbeat_session_id"; #through; case "device_vendor_id"; #through; case "client_ad_session_id";
		return fmt.tprintf("id:%s", key), true, true;
	case "ip"; #through; case "ip_address"; #through; case "remote_ip";
		return "ip", false, true;
	case "country_code"; #through; case "subdivision_code";
		return "geo", false, true;
	}
	return "", false, false;
}
#scope_export

// Header names with fixed scrubbing.
header_rule :: (c: *Ctx, name: string, value: string) -> etf.Value, bool {
	lname := strings.to_lower(name, temp);
	if lname == {
	case "authorization";
		return etf.vstring("<token>"), true;
	case "cookie"; #through; case "set-cookie";
		return etf.vstring("<cookie>"), true;
	case "x-fingerprint";
		return etf.vstring(placeholder(c, "id:fingerprint", value)), true;
	case "x-installation-id";
		return etf.vstring(placeholder(c, "id:installation_id", value)), true;
	case "x-captcha-key"; #through; case "x-captcha-rqtoken"; #through; case "x-captcha-session-id";
		return etf.vstring("<token>"), true;
	case "x-super-properties"; #through; case "x-context-properties";
		{ decoded, ok := decode_b64_json(value);
		if ok {
			m := make_slice(etf.Pair, 1);
			m[0] = .{key = etf.vstring("$b64json"), value = scrub_value(c, decoded, "")};
			return etf.vmap(m), true;
		} }
	}
	return .{}, false;
}
#scope_module

decode_b64_json :: (s: string) -> etf.Value, bool {
	raw, err := b64_decode(s);
	if !err { return .{}, false; }
	v, jerr := etf.from_json(as_string(raw));
	return v, jerr == .None;
}
#scope_export

is_snowflake_digits :: (s: string) -> bool {
	if len(s) < 17 || len(s) > 20 { return false; }
	for ch: transmute([]u8, s) { if ch < #char "0" || ch > #char "9" { return false; } }
	return true;
}

// snowflake_ms returns the creation time of a plausible snowflake (0 if implausible).
snowflake_ms :: (s: string) -> s64 {
	x, ok := strconv.parse_u64_of_base(s, 10);
	if !ok { return 0; }
	ms := cast(s64)(x >> 22) + DISCORD_EPOCH;
	if ms < 1430000000000 || ms > 2200000000000 { return 0; }
	return ms;
}

// classify_snowflake returns the replacement for a snowflake string ("" = keep).
classify_snowflake :: (c: *Ctx, s: string) -> string {
	if get(c.allow, s) { return ""; }
	if get(c.others, s) { return placeholder(c, "user", s); }
	ms := snowflake_ms(s);
	if ms == 0 { return ""; }
	if c.run_start_ms > 0 && ms >= c.run_start_ms - 120_000 { return placeholder(c, "new", s); }
	return "";
}
#scope_module

is_b64url :: (ch: u8) -> bool {
	return (ch >= #char "a" && ch <= #char "z") || (ch >= #char "A" && ch <= #char "Z") || (ch >= #char "0" && ch <= #char "9") || ch == #char "-" || ch == #char "_";
}

is_hex :: (ch: u8) -> bool {return (ch >= #char "0" && ch <= #char "9") || (ch >= #char "a" && ch <= #char "f") || (ch >= #char "A" && ch <= #char "F");}
#scope_export

// token_at: Discord user tokens look like <24-28>.<6>.<27-40> base64url segments.
token_at :: (s: string, i: int) -> int {
	if i > 0 && is_b64url(s[i - 1]) { return 0; }
	seg := [2]int.[.[24, 30], .[6, 7], .[25, 45]];
	j := i;
	for k: 0..2 {
		n := 0;
		while j < len(s) && is_b64url(s[j]) {
			j += 1;
			n += 1;
		}
		if n < seg[k][0] || n > seg[k][1] { return 0; }
		if k < 2 {
			if j >= len(s) || s[j] != #char "." { return 0; }
			j += 1;
		}
	}
	return j - i;
}
#scope_module

uuid_at :: (s: string, i: int) -> bool {
	if i + 36 > len(s) { return false; }
	if i > 0 && is_hex(s[i - 1]) { return false; }
	if i + 36 < len(s) && is_hex(s[i + 36]) { return false; }
	for k: 0..35 {
		ch := s[i + k];
		if k == 8 || k == 13 || k == 18 || k == 23 {
			if ch != #char "-" { return false; }
		} else if !is_hex(ch) {
			return false;
		}
	}
	return true;
}

email_span :: (s: string, at: int) -> int, int, bool {
	start: int;
	end: int;
	ok: bool;
	start = at;
	while start > 0 && (is_b64url(s[start - 1]) || s[start - 1] == #char "." || s[start - 1] == #char "+" || s[start - 1] == #char "%") { start -= 1; }
	end = at + 1;
	dot := false;
	while end < len(s) && (is_b64url(s[end]) || s[end] == #char ".") {
		if s[end] == #char "." { dot = true; }
		end += 1;
	}
	while end > at + 1 && s[end - 1] == #char "." { end -= 1; }
	return start, end, start < at && dot && end > at + 3;
}
#scope_export

// scrub_text replaces tokens, emails, UUIDs and snowflakes inside free text.
scrub_text :: (c: *Ctx, s: string) -> string {
	sb := strings.builder_make();
	i := 0;
	while i < len(s) {
		{ n := token_at(s, i);
		if n > 0 {
			strings.write_string(*sb, "<token>");
			i += n;
			continue;
		} }
		// GCS resumable-upload session ids (a capability for the upload URL)
		if strings.has_prefix(sub_from(s, i), "upload_id=") {
			j := i + len("upload_id=");
			k := j;
			while k < len(s) && s[k] != #char "&" && s[k] != 34 && s[k] != #char " " { k += 1; }
			strings.write_string(*sb, "upload_id=");
			if k > j { strings.write_string(*sb, placeholder(c, "upload_id", sub(s, j, k))); }
			i = k;
			continue;
		}
		if uuid_at(s, i) {
			strings.write_string(*sb, placeholder(c, "uuid", strings.to_lower(sub(s, i, i + 36), temp)));
			i += 36;
			continue;
		}
		if s[i] == #char "@" {
			{ st, en, ok := email_span(s, i);
			if ok && len(sb.buf) >= i - st {
				// drop the local part already written, then the placeholder
				resize(*sb.buf, len(sb.buf) - (i - st));
				strings.write_string(*sb, "<email>");
				i = en;
				continue;
			} }
		}
		if s[i] >= #char "0" && s[i] <= #char "9" && (i == 0 || s[i - 1] < #char "0" || s[i - 1] > #char "9") {
			j := i;
			while j < len(s) && s[j] >= #char "0" && s[j] <= #char "9" { j += 1; }
			if is_snowflake_digits(sub(s, i, j)) {
				{ r := classify_snowflake(c, sub(s, i, j));
				if r != "" {
					strings.write_string(*sb, r);
					i = j;
					continue;
				} }
			}
			strings.write_string(*sb, sub(s, i, j));
			i = j;
			continue;
		}
		strings.write_byte(*sb, s[i]);
		i += 1;
	}
	return strings.to_string(sb);
}
#scope_module

user_fields :: (key: string) -> bool {
	if key == {
	case "username"; #through; case "global_name"; #through; case "display_name"; #through; case "nick"; #through; case "bio"; #through; case "pronouns"; #through; case "avatar"; #through; case "banner"; #through; case "avatar_decoration_data"; #through; case "primary_guild"; #through; case "collectibles"; #through; case "clan"; #through; case "display_name_styles";
		return true;
	}
	return false;
}

map_str :: (m: etf.Map, key: string) -> string {
	v, _ := etf.map_get(m, key);
	if v.kind == {
	case .String; x := v.s;
		return x;
	case .Int; x := v.i;
		return fmt.tprintf("%d", x);
	}
	return "";
}
#scope_export

// scrub_value deep-copies v with every rule applied. key is the map key v sits under.
scrub_value :: (c: *Ctx, v: etf.Value, key: string) -> etf.Value {
	{ kind, numbered, ok := key_rule(key);
	if ok {
		if v.kind == {
		case .Nil; #through; case .Bool; x := v;
			return v;
		case .Map; #through; case .List; x := v;
		// structured value under a secret-looking key: recurse instead
		case; x := v;
			if !numbered { return etf.vstring(fmt.aprintf("<%s>", kind)); }
			return etf.vstring(placeholder(c, kind, vtext(x)));
		}
	} }
	if v.kind == {
	case .Nil; #through; case .Bool; #through; case .Float; x := v;
		return v;
	case .Big; x := v.big;
		return etf.vbig(etf.Big.{negative = x.negative, digits = clone(x.digits)});
	case .Atom; x := v.s;
		return etf.vstring(scrub_text(c, as_string(x)));
	case .Charlist; x := v.s;
		return etf.vcharlist(clone(as_string(x)));
	case .Int; x := v.i;
		s := fmt.tprintf("%d", x);
		if is_snowflake_digits(s) {
			{ r := classify_snowflake(c, s);
			if r != "" { return etf.vstring(r); } }
		}
		return v;
	case .String; x := v.s;
		return etf.vstring(scrub_text(c, x));
	case .List; x := v.list;
		out := make_slice(etf.Value, len(x));
		for e, i: x { at(*out, i).* = scrub_value(c, e, key); }
		return etf.vlist(out);
	case .Tuple; x := v.list;
		out := make_slice(etf.Value, len(x));
		for e, i: x { at(*out, i).* = scrub_value(c, e, key); }
		return etf.vtuple(out);
	case .Map; x := v.map;
		// people who are not test accounts: no names/avatars/bios in fixtures
		foreign_user := false;
		{ _, has := etf.map_get(x, "username");
		if has {
			{ id := map_str(x, "id");
			if id != "" && get(c.others, id) { foreign_user = true; } }
		} }
		foreign_author := false;
		{ a, has := etf.map_get(x, "author");
		if has {
			{ am, is_map := a.map, a.kind == .Map;
			if is_map {
				{ id := map_str(am, "id");
				if id != "" && get(c.others, id) { foreign_author = true; } }
			} }
		} }
		out := make_slice(etf.Pair, len(x));
		for p, i: x {
			k := vs(p.key);
			at(*out, i).*.key = scrub_value(c, p.key, ""); // keys can be ids (e.g. guild_versions)
			if foreign_user && user_fields(k) {
				at(*out, i).*.value = ifx k == "username" || k == "global_name" || k == "display_name" || k == "nick" then etf.vstring(placeholder(c, "user", map_str(x, "id"))) else etf.Value.{};
			} else if foreign_author && (k == "content" || k == "attachments" || k == "embeds" || k == "components") {
				at(*out, i).*.value = ifx k == "content" then etf.vstring("<content>") else etf.vlist(.[]);
			} else {
				at(*out, i).*.value = scrub_value(c, p.value, k);
			}
		}
		return etf.vmap(out);
	}
	return v;
}

// collect_foreign records ids of user objects that aren't test accounts.
collect_foreign :: (c: *Ctx, v: etf.Value) {
	if v.kind == {
	case .List; x := v.list;
		for e: x { collect_foreign(c, e); }
	case .Map; x := v.map;
		{ _, has := etf.map_get(x, "username");
		if has {
			{ id := map_str(x, "id");
			if is_snowflake_digits(id) && !get(c.allow, id) { at(*c.others, clone(id)).* = true; } }
		} }
		for p: x { collect_foreign(c, p.value); }
	}
}

