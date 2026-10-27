// Placeholder state for one fixture: the same original always maps to the
// same placeholder, numbered in order of first appearance.
Ctx :: struct {
    allow: Table(string, bool);   // snowflakes kept verbatim (test accounts, test guild, ...)
    others: Table(string, bool);  // user ids of people who are not test accounts
    run_start_ms: s64;            // unix ms; snowflakes created after this are <new:N>
    ph: Table(string, string);    // "kind\0original" -> placeholder
    counts: Table(string, int);
}

DISCORD_EPOCH :: 1420070400000;

placeholder :: (c: *Ctx, kind: string, original: string) -> string {
    key := tprint("%\0%", kind, original);
    found, p := table_find(*c.ph, key);
    if found return p;
    n := find_or_add(*c.counts, copy_string(kind));
    n.* += 1;
    p = sprint("<%:%>", kind, n.*);
    table_add(*c.ph, copy_string(key), p);
    return p;
}

// Keys whose whole value is a secret or per-run identifier.
key_rule :: (key: string) -> kind: string, numbered: bool, ok: bool {
    if key == "client_heartbeat_session_id" || key == "heartbeat_session_id" return tprint("id:%", key), true, true;
    if ends_with(key, "session_id") || ends_with(key, "session_id_hash") || key == "id_hash" return "sid", true, true;
    if array_find(string.["token", "authorization", "auth_token", "captcha_key", "password", "new_password", "ticket", "mfa_token", "access_token", "refresh_token"], key)
        return "token", false, true;
    if key == "email" || key == "email_address" return "email", false, true;
    if key == "phone" || key == "phone_number" return "phone", false, true;
    if key == "nonce" || key == "enforce_nonce" return "nonce", true, true;
    if array_find(string.["analytics_token", "qos_token", "fingerprint", "installation_id", "launch_signature", "client_launch_id", "device_vendor_id"], key)
        return tprint("id:%", key), true, true;
    if key == "ip" || key == "ip_address" || key == "remote_ip" return "ip", false, true;
    if key == "country_code" || key == "subdivision_code" return "geo", false, true;
    return "", false, false;
}

// Header names with fixed scrubbing.
header_rule :: (c: *Ctx, name: string, value: string) -> etf.Value, bool {
    lname := to_lower_copy(name,, temp);
    if lname == "authorization" || lname == "x-captcha-key" || lname == "x-captcha-rqtoken" || lname == "x-captcha-session-id"
        return etf.vstring("<token>"), true;
    if lname == "cookie" || lname == "set-cookie" return etf.vstring("<cookie>"), true;
    if lname == "x-fingerprint"     return etf.vstring(placeholder(c, "id:fingerprint", value)), true;
    if lname == "x-installation-id" return etf.vstring(placeholder(c, "id:installation_id", value)), true;
    if lname == "x-super-properties" || lname == "x-context-properties" {
        raw, ok := b64_decode(value);
        decoded, err := etf.from_json(raw,, temp);
        if ok && err == .None return obj(P("$b64json", scrub_value(c, decoded, ""))), true;
    }
    return .{}, false;
}

is_snowflake_digits :: (s: string) -> bool {
    if s.count < 17 || s.count > 20 return false;
    for cast([]u8) s if it < #char "0" || it > #char "9" return false;
    return true;
}

// snowflake_ms returns the creation time of a plausible snowflake (0 if implausible).
snowflake_ms :: (s: string) -> s64 {
    x: u64;
    for cast([]u8) s {
        d := cast(u64) (it - #char "0");
        if x > (U64_MAX - d) / 10 return 0;
        x = x * 10 + d;
    }
    ms := cast(s64) (x >> 22) + DISCORD_EPOCH;
    if ms < 1430000000000 || ms > 2200000000000 return 0;
    return ms;
}

// classify_snowflake returns the replacement for a snowflake string ("" = keep).
classify_snowflake :: (c: *Ctx, s: string) -> string {
    if table_find_pointer(*c.allow, s) return "";
    if table_find_pointer(*c.others, s) return placeholder(c, "user", s);
    ms := snowflake_ms(s);
    if ms == 0 return "";
    if c.run_start_ms > 0 && ms >= c.run_start_ms - 120_000 return placeholder(c, "new", s);
    return "";
}

is_b64url :: (ch: u8) -> bool {
    return (ch >= #char "a" && ch <= #char "z") || (ch >= #char "A" && ch <= #char "Z") || (ch >= #char "0" && ch <= #char "9") || ch == #char "-" || ch == #char "_";
}

is_hex :: (ch: u8) -> bool { return (ch >= #char "0" && ch <= #char "9") || (ch >= #char "a" && ch <= #char "f") || (ch >= #char "A" && ch <= #char "F"); }

// token_at: Discord user tokens look like <24-28>.<6>.<27-40> base64url segments.
token_at :: (s: string, i: int) -> int {
    if i > 0 && is_b64url(s[i - 1]) return 0;
    SEG :: ([2]int).[.[24, 30], .[6, 7], .[25, 45]];
    j := i;
    for seg, k: SEG {
        n := 0;
        while j < s.count && is_b64url(s[j]) { j += 1; n += 1; }
        if n < seg[0] || n > seg[1] return 0;
        if k < 2 {
            if j >= s.count || s[j] != #char "." return 0;
            j += 1;
        }
    }
    return j - i;
}

uuid_at :: (s: string, i: int) -> bool {
    if i + 36 > s.count return false;
    if i > 0 && is_hex(s[i - 1]) return false;
    if i + 36 < s.count && is_hex(s[i + 36]) return false;
    for k: 0..35 {
        ch := s[i + k];
        if k == 8 || k == 13 || k == 18 || k == 23 {
            if ch != #char "-" return false;
        } else if !is_hex(ch) {
            return false;
        }
    }
    return true;
}

email_span :: (s: string, at: int) -> start: int, end: int, ok: bool {
    start := at;
    while start > 0 && (is_b64url(s[start - 1]) || s[start - 1] == #char "." || s[start - 1] == #char "+" || s[start - 1] == #char "%") start -= 1;
    end := at + 1;
    dot := false;
    while end < s.count && (is_b64url(s[end]) || s[end] == #char ".") {
        if s[end] == #char "." dot = true;
        end += 1;
    }
    while end > at + 1 && s[end - 1] == #char "." end -= 1;
    return start, end, start < at && dot && end > at + 3;
}

// scrub_text replaces tokens, emails, UUIDs and snowflakes inside free text.
scrub_text :: (c: *Ctx, s: string) -> string {
    out: [..]u8;
    put :: (out: *[..]u8, s: string) { array_add(out, ..cast([]u8) s); }
    i := 0;
    while i < s.count {
        n := token_at(s, i);
        if n > 0 {
            put(*out, "<token>");
            i += n;
            continue;
        }
        // GCS resumable-upload session ids (a capability for the upload URL)
        if begins_with(slice(s, i, s.count - i), "upload_id=") {
            j := i + "upload_id=".count;
            k := j;
            while k < s.count && s[k] != #char "&" && s[k] != #char "\"" && s[k] != #char " " k += 1;
            put(*out, "upload_id=");
            if k > j put(*out, placeholder(c, "upload_id", slice(s, j, k - j)));
            i = k;
            continue;
        }
        if uuid_at(s, i) {
            put(*out, placeholder(c, "uuid", to_lower_copy(slice(s, i, 36),, temp)));
            i += 36;
            continue;
        }
        if s[i] == #char "@" {
            st, en, ok := email_span(s, i);
            if ok && out.count >= i - st {
                out.count -= i - st;  // drop the local part already written, then the placeholder
                put(*out, "<email>");
                i = en;
                continue;
            }
        }
        if s[i] >= #char "0" && s[i] <= #char "9" && (i == 0 || s[i - 1] < #char "0" || s[i - 1] > #char "9") {
            j := i;
            while j < s.count && s[j] >= #char "0" && s[j] <= #char "9" j += 1;
            digits := slice(s, i, j - i);
            r := ifx is_snowflake_digits(digits) then classify_snowflake(c, digits) else "";
            put(*out, ifx r then r else digits);
            i = j;
            continue;
        }
        array_add(*out, s[i]);
        i += 1;
    }
    return cast(string) out;
}

user_fields :: (key: string) -> bool {
    found := array_find(string.["username", "global_name", "display_name", "nick", "bio", "pronouns", "avatar", "banner",
        "avatar_decoration_data", "primary_guild", "collectibles", "clan", "display_name_styles"], key);
    return found;
}

map_str :: (m: etf.Map, key: string) -> string {
    v := etf.map_get(m, key);
    if v.kind == .String return v.s;
    if v.kind == .Int    return tprint("%", v.i);
    return "";
}

// text: a value's own text, for placeholder keys (strings bare, the rest as JSON).
text :: (v: etf.Value) -> string {
    if v.kind == .String || v.kind == .Atom || v.kind == .Charlist return v.s;
    sb: String_Builder;
    sb.allocator = temp;
    etf.to_json(v, *sb);
    return builder_to_string(*sb,, temp);
}

// scrub_value deep-copies v with every rule applied. key is the map key v sits under.
scrub_value :: (c: *Ctx, v: etf.Value, key: string) -> etf.Value {
    kind, numbered, ok := key_rule(key);
    // a structured value under a secret-looking key is recursed into instead
    if ok && v.kind != .Nil && v.kind != .Bool && v.kind != .Map && v.kind != .List {
        if !numbered return etf.vstring(sprint("<%>", kind));
        return etf.vstring(placeholder(c, kind, text(v)));
    }
    r := v;
    if v.kind == {
      case .Big;      r.big.digits = array_copy(v.big.digits);
      case .Charlist; r.s = copy_string(v.s);
      case .Atom; #through;
      case .String;   return etf.vstring(scrub_text(c, v.s));
      case .Int;
        s := tprint("%", v.i);
        if is_snowflake_digits(s) {
            repl := classify_snowflake(c, s);
            if repl return etf.vstring(repl);
        }
      case .List; #through;
      case .Tuple;
        r.list = NewArray(v.list.count, etf.Value);
        for v.list r.list[it_index] = scrub_value(c, it, key);
      case .Map;
        // people who are not test accounts: no names/avatars/bios in fixtures
        id := map_str(v.map, "id");
        _, has_username := etf.map_get(v.map, "username");
        foreign_user := has_username && id && table_find_pointer(*c.others, id) != null;
        author := etf.map_get(v.map, "author");
        author_id := ifx author.kind == .Map then map_str(author.map, "id") else "";
        foreign_author := author_id && table_find_pointer(*c.others, author_id) != null;
        r.map = NewArray(v.map.count, etf.Pair);
        for p, i: v.map {
            k := ifx p.key.kind == .String then p.key.s else "";
            out := *r.map[i];
            out.key = scrub_value(c, p.key, "");  // keys can be ids (e.g. guild_versions)
            if foreign_user && user_fields(k) {
                if k == "username" || k == "global_name" || k == "display_name" || k == "nick" out.value = etf.vstring(placeholder(c, "user", id));
            } else if foreign_author && (k == "content" || k == "attachments" || k == "embeds" || k == "components") {
                out.value = ifx k == "content" then etf.vstring("<content>") else etf.vlist(.[]);
            } else {
                out.value = scrub_value(c, p.value, k);
            }
        }
    }
    return r;
}

// collect_foreign records ids of user objects that aren't test accounts.
collect_foreign :: (c: *Ctx, v: etf.Value) {
    if v.kind == .List for v.list collect_foreign(c, it);
    if v.kind != .Map return;
    _, has := etf.map_get(v.map, "username");
    id := map_str(v.map, "id");
    if has && is_snowflake_digits(id) && !table_find_pointer(*c.allow, id) table_set(*c.others, copy_string(id), true);
    for v.map collect_foreign(c, it.value);
}
