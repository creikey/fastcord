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

// The jar is shared by every worker: its cookies and strings live in allocator (under mu).
Cookie_Jar :: struct {
	mu: locks.Mutex;
	cookies: [..]Cookie;
	last_ctime: s64;
	dirty: bool;
	allocator: Allocator;
}

cookie_jar_init :: (j: *Cookie_Jar, allocator := context.allocator) {
	j.allocator = allocator;
	j.cookies.allocator = allocator;
}

cookie_free :: (j: *Cookie_Jar, c: Cookie) {
	push_allocator(j.allocator);
	free(c.name);
	free(c.value);
	free(c.domain);
	free(c.path);
}

cookie_jar_destroy :: (j: *Cookie_Jar) {
	for j.cookies cookie_free(j, it);
	array_free(j.cookies);
}

default_path :: (req_path: string) -> string {
	p := before_query(req_path);
	if !p || p[0] != #char "/" return "/";
	_, dir := split_from_right(p, #char "/");
	return ifx dir then dir else "/";
}

before_query :: (path: string) -> string {
	_, p := split_from_left(path, #char "?");
	return p;
}

// cookie_set_from_header applies one Set-Cookie header received from host.
cookie_set_from_header :: (j: *Cookie_Jar, host: string, req_path: string, header: string, now: s64) {
	parts := split(header, ";",, temp);
	if !parts return;
	found, name, value := split_from_left(trim(parts[0]), #char "=");
	if !found || !name return;
	name, value = trim(name), trim(value);
	c: Cookie;
	domain, path: string;
	max_age_set := false;
	for a: array_view(parts, 1) {
		_, k, v := split_from_left(trim(a), #char "=");
		k, v = trim(k), trim(v);
		if to_lower_copy(k,, temp) == {
			case "domain";   domain = to_lower_copy(trim_left(v, "."),, temp);
			case "path";     path = v;
			case "secure";   c.secure = true;
			case "httponly"; c.http_only = true;
			case "max-age";
				secs, ok := parse_s64(v);
				if ok {
					max_age_set = true;
					c.expires = ifx secs > 0 then now + secs * 1000 else 1;
				}
			case "expires";
				if !max_age_set {
					t, ok := parse_http_date(v);
					if ok c.expires = ifx t > 0 then t else 1;
				}
		}
	}
	lhost := to_lower_copy(host,, temp);
	if !domain {
		domain = lhost;
		c.host_only = true;
	} else if !(lhost == domain || ends_with(lhost, tprint(".%", domain))) {
		return; // domain mismatch: rejected
	}
	if !path || path[0] != #char "/" path = default_path(req_path);

	locks.lock(*j.mu);
	defer locks.unlock(*j.mu);
	for o: j.cookies {
		if o.name == name && o.domain == domain && o.path == path && o.host_only == c.host_only {
			cookie_free(j, o);
			array_ordered_remove_by_index(*j.cookies, it_index);
			break;
		}
	}
	j.dirty = true;
	if c.expires != 0 && c.expires <= now return; // deletion
	push_allocator(j.allocator);
	c.name = copy_string(name);
	c.value = copy_string(value);
	c.domain = copy_string(domain);
	c.path = copy_string(path);
	c.creation = max(now * 1000, j.last_ctime + 1);
	j.last_ctime = c.creation;
	array_add(*j.cookies, c);
}

path_match :: (req_path: string, cookie_path: string) -> bool {
	p := before_query(req_path);
	if p == cookie_path return true;
	if !begins_with(p, cookie_path) return false;
	return ends_with(cookie_path, "/") || (p.count > cookie_path.count && p[cookie_path.count] == #char "/");
}

// cookie_header returns the Cookie header value for a request ("" if none), in temp.
cookie_header :: (j: *Cookie_Jar, host: string, path: string, secure: bool, now: s64) -> string {
	locks.lock(*j.mu);
	defer locks.unlock(*j.mu);
	lhost := to_lower_copy(host,, temp);
	sel: [..]Cookie;
	sel.allocator = temp;
	for c: j.cookies {
		if c.expires != 0 && c.expires <= now continue;
		if c.secure && !secure continue;
		if c.host_only {
			if lhost != c.domain continue;
		} else if !(lhost == c.domain || (ends_with(lhost, c.domain) && lhost.count > c.domain.count && lhost[lhost.count - c.domain.count - 1] == #char ".")) {
			continue;
		}
		if !path_match(path, c.path) continue;
		array_add(*sel, c);
	}
	if !sel return "";
	// creation times are unique, so this order is total (no stability needed)
	quick_sort(sel, (a: Cookie, b: Cookie) -> int {
		if a.path.count != b.path.count return b.path.count - a.path.count;
		return ifx a.creation < b.creation then -1 else 1;
	});
	sb: String_Builder;
	sb.allocator = temp;
	for sel {
		if it_index > 0 append(*sb, "; ");
		print_to_builder(*sb, "%=%", it.name, it.value);
	}
	return builder_to_string(*sb,, temp);
}

cookie_get :: (j: *Cookie_Jar, name: string, domain: string) -> string, bool {
	locks.lock(*j.mu);
	defer locks.unlock(*j.mu);
	for j.cookies if it.name == name && it.domain == domain return it.value, true;
	return "", false;
}

// ---- persistence (tab separated, persistent cookies only) ----

cookie_jar_save :: (j: *Cookie_Jar, path: string, now: s64) -> bool {
	sb: String_Builder;
	sb.allocator = temp;
	locks.lock(*j.mu);
	for c: j.cookies {
		if c.expires == 0 || c.expires <= now continue;
		print_to_builder(*sb, "%\t%\t%\t%\t%\t%\t%\t%\t%\n", c.name, c.value, c.domain, cast(int) c.host_only, c.path, cast(int) c.secure, cast(int) c.http_only, c.expires, c.creation);
	}
	j.dirty = false;
	locks.unlock(*j.mu);
	return write_file_atomic(path, cast([]u8) builder_to_string(*sb,, temp));
}

cookie_jar_load :: (j: *Cookie_Jar, path: string, now: s64) {
	text, ok := read_entire_file(path, log_errors = false,, temp);
	if !ok return;
	locks.lock(*j.mu);
	defer locks.unlock(*j.mu);
	push_allocator(j.allocator);
	for line: split(text, "\n",, temp) {
		f := split(line, "\t",, temp);
		if f.count != 9 continue;
		exp := parse_s64(f[7]);
		ct := parse_s64(trim_right(f[8], "\r"));
		if exp <= now continue;
		array_add(*j.cookies, .{
			name = copy_string(f[0]),
			value = copy_string(f[1]),
			domain = copy_string(f[2]),
			host_only = f[3] == "1",
			path = copy_string(f[4]),
			secure = f[5] == "1",
			http_only = f[6] == "1",
			expires = exp,
			creation = ct
		});
		j.last_ctime = max(j.last_ctime, ct);
	}
}

// parse_http_date parses IMF-fixdate and the common cookie variants
// ("Wed, 21 Oct 2026 07:28:00 GMT", "Wed, 21-Oct-2026 07:28:00 GMT"): unix ms.
parse_http_date :: (s: string) -> s64, bool {
	MONTHS :: string.["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"];
	t := s;
	c := find_index_from_left(t, #char ",");
	if c >= 0 t = advance(t, c + 1);
	t = replace(t, "-", " ",, temp);
	fields: [..]string;
	fields.allocator = temp;
	for split(t, " ",, temp) {
		f := trim(it);
		if f array_add(*fields, f);
	}
	if fields.count < 4 return 0, false;
	day, ok1 := parse_s64(fields[0]);
	mon := -1;
	ml := to_lower_copy(fields[1],, temp);
	for MONTHS if begins_with(ml, it) mon = it_index + 1;
	year, ok2 := parse_s64(fields[2]);
	hms := split(fields[3], ":",, temp);
	if !ok1 || !ok2 || mon < 0 || hms.count != 3 return 0, false;
	if year < 100 year += ifx year < 70 then 2000 else 1900;
	hh := parse_s64(hms[0]);
	mm := parse_s64(hms[1]);
	ss := parse_s64(hms[2]);
	if day < 1 || day > 31 || hh < 0 || hh > 23 || mm < 0 || mm > 59 || ss < 0 || ss > 60 return 0, false;
	// days from civil (Howard Hinnant), proleptic Gregorian, UTC
	y := ifx mon <= 2 then year - 1 else year;
	era := (ifx y >= 0 then y else y - 399) / 400;
	yoe := y - era * 400;
	doy := (153 * (ifx mon > 2 then mon - 3 else mon + 9) + 2) / 5 + day - 1;
	doe := yoe * 365 + yoe / 4 - yoe / 100 + doy;
	days := era * 146097 + doe - 719468;
	return (days * 86400 + hh * 3600 + mm * 60 + ss) * 1000, true;
}

write_file_atomic :: (path: string, data: []u8) -> bool {
	tmp := tprint("%.tmp", path);
	return write_entire_file(tmp, cast(string) data) && file_move(tmp, path);
}
