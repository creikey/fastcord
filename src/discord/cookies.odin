package discord

import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"

// Cookie jar with Chrome's selection and ordering rules: domain/path match,
// sorted by path length (longest first) then creation time (oldest first).
// Only persistent cookies (Expires/Max-Age) survive a restart, like Chrome.
Cookie :: struct {
	name, value: string,
	domain:      string, // lowercase, no leading dot
	host_only:   bool,
	path:        string,
	secure:      bool,
	http_only:   bool,
	expires:     i64, // unix ms; 0 = session cookie
	creation:    i64, // unix µs, unique (Chrome bumps duplicates)
}

Cookie_Jar :: struct {
	mu:        sync.Mutex,
	cookies:   [dynamic]Cookie,
	last_ctime: i64,
	dirty:     bool,
	allocator: Allocator,
}

cookie_jar_init :: proc(j: ^Cookie_Jar, allocator := context.allocator) {
	j.allocator = allocator
	j.cookies = make([dynamic]Cookie, allocator)
}

@(private)
cookie_free :: proc(j: ^Cookie_Jar, c: Cookie) {
	delete(c.name, j.allocator)
	delete(c.value, j.allocator)
	delete(c.domain, j.allocator)
	delete(c.path, j.allocator)
}

cookie_jar_destroy :: proc(j: ^Cookie_Jar) {
	for c in j.cookies do cookie_free(j, c)
	delete(j.cookies)
}

@(private)
next_ctime :: proc(j: ^Cookie_Jar, now_ms_: i64) -> i64 {
	t := now_ms_ * 1000
	if t <= j.last_ctime do t = j.last_ctime + 1
	j.last_ctime = t
	return t
}

@(private)
default_path :: proc(req_path: string) -> string {
	p := req_path
	if q := strings.index_byte(p, '?'); q >= 0 do p = p[:q]
	if len(p) == 0 || p[0] != '/' do return "/"
	i := strings.last_index_byte(p, '/')
	if i <= 0 do return "/"
	return p[:i]
}

// cookie_set_from_header applies one Set-Cookie header received from host.
cookie_set_from_header :: proc(j: ^Cookie_Jar, host, req_path, header: string, now: i64) {
	parts := strings.split(header, ";", context.temp_allocator)
	if len(parts) == 0 do return
	nv := strings.trim_space(parts[0])
	eq := strings.index_byte(nv, '=')
	if eq <= 0 do return
	c: Cookie
	name := strings.trim_space(nv[:eq])
	value := strings.trim_space(nv[eq + 1:])
	domain := ""
	path := ""
	max_age_set := false
	for a in parts[1:] {
		at := strings.trim_space(a)
		k, v := at, ""
		if e := strings.index_byte(at, '='); e >= 0 {
			k = strings.trim_space(at[:e])
			v = strings.trim_space(at[e + 1:])
		}
		switch strings.to_lower(k, context.temp_allocator) {
		case "domain":
			domain = strings.to_lower(strings.trim_left(v, "."), context.temp_allocator)
		case "path":
			path = v
		case "secure":
			c.secure = true
		case "httponly":
			c.http_only = true
		case "max-age":
			if secs, ok := strconv.parse_i64(v); ok {
				max_age_set = true
				c.expires = now + secs * 1000 if secs > 0 else 1
			}
		case "expires":
			if !max_age_set {
				if t, ok := parse_http_date(v); ok do c.expires = t if t > 0 else 1
			}
		}
	}
	lhost := strings.to_lower(host, context.temp_allocator)
	if domain == "" {
		domain = lhost
		c.host_only = true
	} else if !(lhost == domain || strings.has_suffix(lhost, strings.concatenate({".", domain}, context.temp_allocator))) {
		return // domain mismatch: rejected
	}
	if path == "" || path[0] != '/' do path = default_path(req_path)

	sync.mutex_lock(&j.mu)
	defer sync.mutex_unlock(&j.mu)
	for i := 0; i < len(j.cookies); i += 1 {
		o := j.cookies[i]
		if o.name == name && o.domain == domain && o.path == path && o.host_only == c.host_only {
			cookie_free(j, o)
			ordered_remove(&j.cookies, i)
			break
		}
	}
	j.dirty = true
	if c.expires != 0 && c.expires <= now do return // deletion
	c.name = strings.clone(name, j.allocator)
	c.value = strings.clone(value, j.allocator)
	c.domain = strings.clone(domain, j.allocator)
	c.path = strings.clone(path, j.allocator)
	c.creation = next_ctime(j, now)
	append(&j.cookies, c)
}

@(private)
path_match :: proc(req_path, cookie_path: string) -> bool {
	p := req_path
	if q := strings.index_byte(p, '?'); q >= 0 do p = p[:q]
	if p == cookie_path do return true
	if strings.has_prefix(p, cookie_path) {
		if strings.has_suffix(cookie_path, "/") do return true
		if len(p) > len(cookie_path) && p[len(cookie_path)] == '/' do return true
	}
	return false
}

// cookie_header returns the Cookie header value for a request ("" if none).
cookie_header :: proc(j: ^Cookie_Jar, host, path: string, secure: bool, now: i64, allocator := context.temp_allocator) -> string {
	sync.mutex_lock(&j.mu)
	defer sync.mutex_unlock(&j.mu)
	lhost := strings.to_lower(host, context.temp_allocator)
	sel := make([dynamic]Cookie, 0, 8, context.temp_allocator)
	for c in j.cookies {
		if c.expires != 0 && c.expires <= now do continue
		if c.secure && !secure do continue
		if c.host_only {
			if lhost != c.domain do continue
		} else if !(lhost == c.domain || (strings.has_suffix(lhost, c.domain) && len(lhost) > len(c.domain) && lhost[len(lhost) - len(c.domain) - 1] == '.')) {
			continue
		}
		if !path_match(path, c.path) do continue
		append(&sel, c)
	}
	if len(sel) == 0 do return ""
	slice.stable_sort_by(sel[:], proc(a, b: Cookie) -> bool {
		if len(a.path) != len(b.path) do return len(a.path) > len(b.path)
		return a.creation < b.creation
	})
	sb := strings.builder_make(allocator)
	for c, i in sel {
		if i > 0 do strings.write_string(&sb, "; ")
		strings.write_string(&sb, c.name)
		strings.write_byte(&sb, '=')
		strings.write_string(&sb, c.value)
	}
	return strings.to_string(sb)
}

cookie_get :: proc(j: ^Cookie_Jar, name, domain: string) -> (string, bool) {
	sync.mutex_lock(&j.mu)
	defer sync.mutex_unlock(&j.mu)
	for c in j.cookies do if c.name == name && c.domain == domain do return c.value, true
	return "", false
}

// ---- persistence (tab separated, persistent cookies only) ----

cookie_jar_save :: proc(j: ^Cookie_Jar, path: string, now: i64) -> bool {
	sync.mutex_lock(&j.mu)
	sb := strings.builder_make(context.temp_allocator)
	for c in j.cookies {
		if c.expires == 0 || c.expires <= now do continue
		strings.write_string(&sb, c.name)
		strings.write_byte(&sb, '\t')
		strings.write_string(&sb, c.value)
		strings.write_byte(&sb, '\t')
		strings.write_string(&sb, c.domain)
		strings.write_byte(&sb, '\t')
		strings.write_string(&sb, "1" if c.host_only else "0")
		strings.write_byte(&sb, '\t')
		strings.write_string(&sb, c.path)
		strings.write_byte(&sb, '\t')
		strings.write_string(&sb, "1" if c.secure else "0")
		strings.write_byte(&sb, '\t')
		strings.write_string(&sb, "1" if c.http_only else "0")
		strings.write_byte(&sb, '\t')
		strings.write_i64(&sb, c.expires)
		strings.write_byte(&sb, '\t')
		strings.write_i64(&sb, c.creation)
		strings.write_byte(&sb, '\n')
	}
	j.dirty = false
	sync.mutex_unlock(&j.mu)
	return write_file_atomic(path, transmute([]byte)strings.to_string(sb))
}

cookie_jar_load :: proc(j: ^Cookie_Jar, path: string, now: i64) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return
	sync.mutex_lock(&j.mu)
	defer sync.mutex_unlock(&j.mu)
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		f := strings.split(line, "\t", context.temp_allocator)
		if len(f) != 9 do continue
		exp, _ := strconv.parse_i64(f[7])
		ct, _ := strconv.parse_i64(f[8])
		if exp <= now do continue
		append(&j.cookies, Cookie{
			name = strings.clone(f[0], j.allocator),
			value = strings.clone(f[1], j.allocator),
			domain = strings.clone(f[2], j.allocator),
			host_only = f[3] == "1",
			path = strings.clone(f[4], j.allocator),
			secure = f[5] == "1",
			http_only = f[6] == "1",
			expires = exp,
			creation = ct,
		})
		if ct > j.last_ctime do j.last_ctime = ct
	}
}

// parse_http_date parses IMF-fixdate and the common cookie variants
// ("Wed, 21 Oct 2026 07:28:00 GMT", "Wed, 21-Oct-2026 07:28:00 GMT").
parse_http_date :: proc(s: string) -> (unix_ms: i64, ok: bool) {
	MONTHS := [12]string{"jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"}
	t := s
	if c := strings.index_byte(t, ','); c >= 0 do t = t[c + 1:]
	t, _ = strings.replace_all(t, "-", " ", context.temp_allocator)
	fields := strings.fields(t, context.temp_allocator)
	if len(fields) < 4 do return 0, false
	day, ok1 := strconv.parse_int(fields[0])
	mon := -1
	ml := strings.to_lower(fields[1], context.temp_allocator)
	for m, i in MONTHS do if strings.has_prefix(ml, m) do mon = i + 1
	year, ok2 := strconv.parse_int(fields[2])
	hms := strings.split(fields[3], ":", context.temp_allocator)
	if !ok1 || !ok2 || mon < 0 || len(hms) != 3 do return 0, false
	if year < 100 do year += 2000 if year < 70 else 1900
	hh, _ := strconv.parse_int(hms[0])
	mm, _ := strconv.parse_int(hms[1])
	ss, _ := strconv.parse_int(hms[2])
	dt, dok := time.components_to_time(year, mon, day, hh, mm, ss)
	if !dok do return 0, false
	return time.time_to_unix_nano(dt) / 1e6, true
}

write_file_atomic :: proc(path: string, data: []byte) -> bool {
	tmp := strings.concatenate({path, ".tmp"}, context.temp_allocator)
	if os.write_entire_file(tmp, data) != nil do return false
	return os.rename(tmp, path) == nil
}
