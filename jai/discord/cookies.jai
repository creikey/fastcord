// Cookie jar with Chrome's selection and ordering rules: domain/path match,
// sorted by path length (longest first) then creation time (oldest first).
// Only persistent cookies (Expires/Max-Age) survive a restart, like Chrome.
Cookie :: struct {
	name, value: string;
	domain: string; // lowercase, no leading dot
	host_only: bool;
	path: string;
	secure: bool;
	http_only: bool;
	expires: s64; // unix ms; 0 = session cookie
	creation: s64; // unix µs, unique (Chrome bumps duplicates)
}

Cookie_Jar :: struct {
	mu: locks.Mutex;
	cookies: [..]Cookie;
	last_ctime: s64;
	dirty: bool;
	allocator: Allocator;
}

cookie_jar_init :: (j: *Cookie_Jar, allocator := context.allocator) {
	j.allocator = allocator;
	j.cookies = make_dynamic(Cookie, 0, 0, allocator);
}
#scope_module

cookie_free :: (j: *Cookie_Jar, c: Cookie) {
	delete(c.name, j.allocator);
	delete(c.value, j.allocator);
	delete(c.domain, j.allocator);
	delete(c.path, j.allocator);
}
#scope_export

cookie_jar_destroy :: (j: *Cookie_Jar) {
	for c: j.cookies { cookie_free(j, c); }
	delete(j.cookies);
}
#scope_module

next_ctime :: (j: *Cookie_Jar, now_ms_: s64) -> s64 {
	t := now_ms_ * 1000;
	if t <= j.last_ctime { t = j.last_ctime + 1; }
	j.last_ctime = t;
	return t;
}

default_path :: (req_path: string) -> string {
	p := req_path;
	{ q := strings.index_byte(p, #char "?");
	if q >= 0 { p = sub(p, 0, q); } }
	if len(p) == 0 || p[0] != #char "/" { return "/"; }
	i := strings.last_index_byte(p, #char "/");
	if i <= 0 { return "/"; }
	return sub(p, 0, i);
}
#scope_export

// cookie_set_from_header applies one Set-Cookie header received from host.
cookie_set_from_header :: (j: *Cookie_Jar, host: string, req_path: string, header: string, now: s64) {
	parts := strings.split(header, ";", temp);
	if len(parts) == 0 { return; }
	nv := strings.trim_space(parts[0]);
	eq := strings.index_byte(nv, #char "=");
	if eq <= 0 { return; }
	c: Cookie;
	name := strings.trim_space(sub(nv, 0, eq));
	value := strings.trim_space(sub_from(nv, eq + 1));
	domain := "";
	path := "";
	max_age_set := false;
	for a: sub_from(parts, 1) {
		at := strings.trim_space(a);
		k, v := at, "";
		{ e := strings.index_byte(at, #char "=");
		if e >= 0 {
			k = strings.trim_space(sub(at, 0, e));
			v = strings.trim_space(sub_from(at, e + 1));
		} }
		if strings.to_lower(k, temp) == {
		case "domain";
			domain = strings.to_lower(strings.trim_left(v, "."), temp);
		case "path";
			path = v;
		case "secure";
			c.secure = true;
		case "httponly";
			c.http_only = true;
		case "max-age";
			{ secs, ok := strconv.parse_i64(v);
			if ok {
				max_age_set = true;
				c.expires = ifx secs > 0 then now + secs * 1000 else 1;
			} }
		case "expires";
			if !max_age_set {
				{ t, ok := parse_http_date(v);
				if ok { c.expires = ifx t > 0 then t else 1; } }
			}
		}
	}
	lhost := strings.to_lower(host, temp);
	if domain == "" {
		domain = lhost;
		c.host_only = true;
	} else if !(lhost == domain || strings.has_suffix(lhost, strings.concatenate(string.[".", domain], temp))) {
		return; // domain mismatch: rejected
	}
	if path == "" || path[0] != #char "/" { path = default_path(req_path); }

	locks.lock(*j.mu);
	defer locks.unlock(*j.mu);
	for i: 0..len(j.cookies)-1 {
		o := j.cookies[i];
		if o.name == name && o.domain == domain && o.path == path && o.host_only == c.host_only {
			cookie_free(j, o);
			ordered_remove(*j.cookies, i);
			break;
		}
	}
	j.dirty = true;
	if c.expires != 0 && c.expires <= now { return; } // deletion
	c.name = clone(name, j.allocator);
	c.value = clone(value, j.allocator);
	c.domain = clone(domain, j.allocator);
	c.path = clone(path, j.allocator);
	c.creation = next_ctime(j, now);
	append(*j.cookies, c);
}
#scope_module

path_match :: (req_path: string, cookie_path: string) -> bool {
	p := req_path;
	{ q := strings.index_byte(p, #char "?");
	if q >= 0 { p = sub(p, 0, q); } }
	if p == cookie_path { return true; }
	if strings.has_prefix(p, cookie_path) {
		if strings.has_suffix(cookie_path, "/") { return true; }
		if len(p) > len(cookie_path) && p[len(cookie_path)] == #char "/" { return true; }
	}
	return false;
}
#scope_export

// cookie_header returns the Cookie header value for a request ("" if none).
cookie_header :: (j: *Cookie_Jar, host: string, path: string, secure: bool, now: s64, allocator := temp) -> string {
	locks.lock(*j.mu);
	defer locks.unlock(*j.mu);
	lhost := strings.to_lower(host, temp);
	sel := make_dynamic(Cookie, 0, 8, temp);
	for c: j.cookies {
		if c.expires != 0 && c.expires <= now { continue; }
		if c.secure && !secure { continue; }
		if c.host_only {
			if lhost != c.domain { continue; }
		} else if !(lhost == c.domain || (strings.has_suffix(lhost, c.domain) && len(lhost) > len(c.domain) && lhost[len(lhost) - len(c.domain) - 1] == #char ".")) {
			continue;
		}
		if !path_match(path, c.path) { continue; }
		append(*sel, c);
	}
	if len(sel) == 0 { return ""; }
	slice.stable_sort_by(view(sel), (a: Cookie, b: Cookie) -> bool {
		if len(a.path) != len(b.path) { return len(a.path) > len(b.path); }
		return a.creation < b.creation;
	});
	sb := strings.builder_make(allocator);
	for c, i: sel {
		if i > 0 { strings.write_string(*sb, "; "); }
		strings.write_string(*sb, c.name);
		strings.write_byte(*sb, #char "=");
		strings.write_string(*sb, c.value);
	}
	return strings.to_string(sb);
}

cookie_get :: (j: *Cookie_Jar, name: string, domain: string) -> string, bool {
	locks.lock(*j.mu);
	defer locks.unlock(*j.mu);
	for c: j.cookies { if c.name == name && c.domain == domain { return c.value, true; } }
	return "", false;
}

// ---- persistence (tab separated, persistent cookies only) ----

cookie_jar_save :: (j: *Cookie_Jar, path: string, now: s64) -> bool {
	locks.lock(*j.mu);
	sb := strings.builder_make(temp);
	for c: j.cookies {
		if c.expires == 0 || c.expires <= now { continue; }
		strings.write_string(*sb, c.name);
		strings.write_byte(*sb, 9);
		strings.write_string(*sb, c.value);
		strings.write_byte(*sb, 9);
		strings.write_string(*sb, c.domain);
		strings.write_byte(*sb, 9);
		strings.write_string(*sb, ifx c.host_only then "1" else "0");
		strings.write_byte(*sb, 9);
		strings.write_string(*sb, c.path);
		strings.write_byte(*sb, 9);
		strings.write_string(*sb, ifx c.secure then "1" else "0");
		strings.write_byte(*sb, 9);
		strings.write_string(*sb, ifx c.http_only then "1" else "0");
		strings.write_byte(*sb, 9);
		strings.write_i64(*sb, c.expires);
		strings.write_byte(*sb, 9);
		strings.write_i64(*sb, c.creation);
		strings.write_byte(*sb, 10);
	}
	j.dirty = false;
	locks.unlock(*j.mu);
	return write_file_atomic(path, transmute([]u8, strings.to_string(sb)));
}

cookie_jar_load :: (j: *Cookie_Jar, path: string, now: s64) {
	data, err := os.read_entire_file(path, temp);
	if err != null { return; }
	locks.lock(*j.mu);
	defer locks.unlock(*j.mu);
	text := as_string(data);
	while true { line, __ok2 := strings.split_lines_iterator(*text); if !__ok2 break;
		f := strings.split(line, "\t", temp);
		if len(f) != 9 { continue; }
		exp, _ := strconv.parse_i64(f[7]);
		ct, _ := strconv.parse_i64(f[8]);
		if exp <= now { continue; }
		append(*j.cookies, Cookie.{
			name = clone(f[0], j.allocator),
			value = clone(f[1], j.allocator),
			domain = clone(f[2], j.allocator),
			host_only = f[3] == "1",
			path = clone(f[4], j.allocator),
			secure = f[5] == "1",
			http_only = f[6] == "1",
			expires = exp,
			creation = ct
		});
		if ct > j.last_ctime { j.last_ctime = ct; }
	}
}

// parse_http_date parses IMF-fixdate and the common cookie variants
// ("Wed, 21 Oct 2026 07:28:00 GMT", "Wed, 21-Oct-2026 07:28:00 GMT").
parse_http_date :: (s: string) -> s64, bool {
	unix_ms: s64;
	ok: bool;
	MONTHS := string.["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"];
	t := s;
	{ c := strings.index_byte(t, #char ",");
	if c >= 0 { t = sub_from(t, c + 1); } }
	t, _ = strings.replace_all(t, "-", " ", temp);
	fields := strings.fields(t, temp);
	if len(fields) < 4 { return 0, false; }
	day, ok1 := strconv.parse_int(fields[0]);
	mon := -1;
	ml := strings.to_lower(fields[1], temp);
	for m, i: MONTHS { if strings.has_prefix(ml, m) { mon = i + 1; } }
	year, ok2 := strconv.parse_int(fields[2]);
	hms := strings.split(fields[3], ":", temp);
	if !ok1 || !ok2 || mon < 0 || len(hms) != 3 { return 0, false; }
	if year < 100 { year += ifx year < 70 then 2000 else 1900; }
	hh, _ := strconv.parse_int(hms[0]);
	mm, _ := strconv.parse_int(hms[1]);
	ss, _ := strconv.parse_int(hms[2]);
	dt, dok := time.components_to_time(year, mon, day, hh, mm, ss);
	if !dok { return 0, false; }
	return time.time_to_unix_nano(dt) / 1000000, true;
}

write_file_atomic :: (path: string, data: []u8) -> bool {
	tmp := strings.concatenate(string.[path, ".tmp"], temp);
	if os.write_entire_file(tmp, data) != null { return false; }
	return os.rename(tmp, path) == null;
}

