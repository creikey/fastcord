// Link previews, as Discord's embeds: after a message is sent or edited, one worker thread fetches the
// page behind each of its first few links and stores the page's title, description and site name, then
// sends MESSAGE_UPDATE with them. Only public addresses are fetched, so a member can't point the server
// at its own network. Images aren't fetched: members would load them straight from the linked site,
// showing it their address.

#scope_module

MAX_LINKS :: 3;
MAX_EMBEDS :: 10;
UNFURL_QUEUE :: 64;
UNFURL_TIMEOUT_MS :: 5000;
MAX_PAGE :: 2 << 20;
MAX_REDIRECTS :: 3;
UNFURL_AGENT :: "Mozilla/5.0 (compatible; fastcord-serve; +https://creikey.com/fastcord)";

Unfurl_Job :: struct {
	message: s64;
	urls: [MAX_LINKS]string; // From the default allocator.
	count: int;
}

Page :: struct {
	title: string;
	description: string;
	site: string;
	color: int;
}

// queue_unfurl asks the worker for previews of content's links; a full queue drops the request.
queue_unfurl :: (s: *Server, message: s64, content: string) {
	urls := link_urls(content);
	if !urls.count return;
	locks.guard(*s.unfurl_mu);
	if s.unfurl_jobs.count >= UNFURL_QUEUE return;
	j := array_add(*s.unfurl_jobs);
	j.message = message;
	for urls j.urls[it_index] = copy_string(it,, context.default_allocator);
	j.count = urls.count;
	locks.cond_signal(*s.unfurl_wake);
}

unfurler :: (s: *Server) {
	while true {
		reset_temporary_storage();
		locks.lock(*s.unfurl_mu);
		while !s.unfurl_jobs.count && !s.unfurl_stop locks.cond_wait(*s.unfurl_wake, *s.unfurl_mu);
		if s.unfurl_stop {
			for s.unfurl_jobs free_job(*it);
			array_free(s.unfurl_jobs);
			locks.unlock(*s.unfurl_mu);
			return;
		}
		j := s.unfurl_jobs[0];
		array_ordered_remove_by_index(*s.unfurl_jobs, 0);
		locks.unlock(*s.unfurl_mu);
		defer free_job(*j);

		Found :: struct { url: string; page: Page; }
		found: [..]Found;
		found.allocator = temp;
		for url: array_view(j.urls, 0, j.count) {
			page, ok := unfurl(s, url);
			if ok array_add(*found, .{url, page});
		}
		if !found.count continue;
		m: etf.Value;
		{
			locks.guard(*s.db_mu);
			// The message may have gone, or been edited to other links, while its pages loaded.
			st := sqlite.prepare(s.db, "SELECT content, flags FROM messages WHERE id = ?;");
			sqlite.bind(st, 1, j.message);
			content := "";
			if sqlite.step(st) == .Row && !(sqlite.col_int(st, 1) & SUPPRESS_EMBEDS) content = copy_string(sqlite.col_text(st, 0),, temp);
			sqlite.finalize(st);
			now := link_urls(content);
			ok := sqlite.exec(s.db, "BEGIN;") && sqlite.run(s.db, "DELETE FROM embeds WHERE message = ? AND rich IS NULL;", j.message);
			for found if ok && array_find(now, it.url) {
				ok = sqlite.run(s.db, "INSERT INTO embeds(message, position, url, title, description, provider, color) VALUES(?, ?, ?, coalesce(?, ''), coalesce(?, ''), coalesce(?, ''), ?);",
					j.message, MAX_EMBEDS + it_index, it.url, it.page.title, it.page.description, it.page.site, it.page.color);
			}
			if !ok || !sqlite.exec(s.db, "COMMIT;") { sqlite.exec(s.db, "ROLLBACK;"); continue; }
			if content m = message_locked(s, j.message, nested = false);
		}
		if m.kind == .Map broadcast(s, "MESSAGE_UPDATE", m);
	}
}

free_job :: (j: *Unfurl_Job) {
	for 0..j.count - 1 free(j.urls[it],, context.default_allocator);
}

// embeds_locked lists a message's embeds as Discord sends them, a webhook's own before its link previews,
// leaving the webhook's out when the message suppresses embeds; the caller holds db_mu.
embeds_locked :: (s: *Server, message: s64, suppressed := false) -> etf.Value {
	list: [..]etf.Value;
	list.allocator = temp;
	st := sqlite.prepare(s.db, "SELECT url, title, description, provider, color, rich FROM embeds WHERE message = ? AND (rich IS NULL OR ? = 0) ORDER BY position;");
	defer sqlite.finalize(st);
	sqlite.bind_all(st, message, cast(int) suppressed);
	while sqlite.step(st) == .Row {
		text :: (i: int) -> string #expand { return copy_string(sqlite.col_text(`st, i),, temp); }
		if !sqlite.col_is_null(st, 5) {
			v, err := etf.from_json(text(5),, temp);
			if err == .None && v.kind == .Map array_add(*list, v);
			continue;
		}
		e := etf.map_builder(6,, temp);
		etf.map_put(*e, "type", etf.vstring("link"));
		etf.map_put(*e, "url", etf.vstring(text(0)));
		if text(1) etf.map_put(*e, "title", etf.vstring(text(1)));
		if text(2) etf.map_put(*e, "description", etf.vstring(text(2)));
		if text(3) {
			p := etf.map_builder(1,, temp);
			etf.map_put(*p, "name", etf.vstring(text(3)));
			etf.map_put(*e, "provider", etf.vmap(etf.map_done(*p)));
		}
		color := sqlite.col_int(st, 4);
		if color etf.map_put(*e, "color", etf.vint(color));
		array_add(*list, etf.vmap(etf.map_done(*e)));
	}
	return etf.vlist(list);
}

// webhook_embeds checks a webhook post's `embeds` against Discord's limits and keeps what fastcord stores:
// title, description, url, color, timestamp, author and footer text, and fields, each embed re-encoded as
// JSON for the embeds table's `rich` column. Images are left out, since members would load them from
// wherever the poster points (see the file comment). In temp.
webhook_embeds :: (v: etf.Value) -> []string, bool {
	out: [..]string;
	out.allocator = temp;
	if v.kind == .Nil return out, true;
	if v.kind != .List || v.list.count > MAX_EMBEDS return out, false;
	total := 0;
	text :: (m: etf.Map, key: string, max: int, total: *int, lines := false) -> etf.Value, bool {
		v, found := etf.map_get(m, key);
		if !found || v.kind == .Nil return .{}, true;
		if v.kind != .String || !text_ok(v.s, lines) || utf16_units(v.s) > max return .{}, false;
		total.* += utf16_units(v.s);
		return ifx trim(v.s) then v else .{}, true;
	}
	sub :: (m: etf.Map, key: string, max: int, total: *int) -> etf.Value, bool {
		v, found := etf.map_get(m, key);
		if !found || v.kind == .Nil return .{}, true;
		if v.kind != .Map return .{}, false;
		name, ok := text(v.map, ifx key == "footer" then "text" else "name", max, total);
		if !ok || name.kind == .Nil return .{}, ok;
		r := etf.map_builder(1,, temp);
		etf.map_put(*r, ifx key == "footer" then "text" else "name", name);
		return etf.vmap(etf.map_done(*r)), true;
	}
	for e: v.list {
		if e.kind != .Map return out, false;
		r := etf.map_builder(9,, temp);
		etf.map_put(*r, "type", etf.vstring("rich"));
		has := false;
		for key: string.["title", "description"] {
			t, ok := text(e.map, key, ifx key == "title" then 256 else 4096, *total, lines = key == "description");
			if !ok return out, false;
			if t.kind != .Nil { etf.map_put(*r, key, t); has = true; }
		}
		for key: string.["author", "footer"] {
			t, ok := sub(e.map, key, ifx key == "author" then 256 else 2048, *total);
			if !ok return out, false;
			if t.kind != .Nil { etf.map_put(*r, key, t); has = true; }
		}
		url, has_url := etf.map_get(e.map, "url");
		if has_url && url.kind != .Nil {
			if url.kind != .String || url.s.count > 2048 || !text_ok(url.s) || contains(url.s, " ") return out, false;
			if !begins_with(url.s, "https://") && !begins_with(url.s, "http://") return out, false;
			etf.map_put(*r, "url", url);
		}
		color, has_color := etf.map_get(e.map, "color");
		if has_color && color.kind != .Nil {
			if color.kind != .Int || color.i < 0 || color.i > 0xFFFFFF return out, false;
			etf.map_put(*r, "color", color);
		}
		ts, has_ts := etf.map_get(e.map, "timestamp");
		if has_ts && ts.kind != .Nil {
			if ts.kind != .String || !ts.s || ts.s.count > 40 return out, false;
			for 0..ts.s.count - 1 if !is_digit(ts.s[it]) && !array_find(cast([]u8) "-:T.+Z", ts.s[it]) return out, false;
			etf.map_put(*r, "timestamp", ts);
		}
		fields, has_fields := etf.map_get(e.map, "fields");
		if has_fields && fields.kind != .Nil {
			if fields.kind != .List || fields.list.count > 25 return out, false;
			kept: [..]etf.Value;
			kept.allocator = temp;
			for f: fields.list {
				if f.kind != .Map return out, false;
				name, ok := text(f.map, "name", 256, *total);
				value, ok2 := text(f.map, "value", 1024, *total, lines = true);
				side, _ := etf.map_get(f.map, "inline");
				if !ok || !ok2 || name.kind == .Nil || value.kind == .Nil || (side.kind != .Nil && side.kind != .Bool) return out, false;
				fm := etf.map_builder(3,, temp);
				etf.map_put(*fm, "name", name);
				etf.map_put(*fm, "value", value);
				etf.map_put(*fm, "inline", etf.vbool(side.kind == .Bool && side.b));
				array_add(*kept, etf.vmap(etf.map_done(*fm)));
			}
			if kept.count { etf.map_put(*r, "fields", etf.vlist(kept)); has = true; }
		}
		if !has || total > 6000 return out, false;
		sb: String_Builder;
		sb.allocator = temp;
		etf.to_json(etf.vmap(etf.map_done(*r)), *sb);
		array_add(*out, builder_to_string(*sb,, temp));
	}
	return out, true;
}

// link_urls finds up to MAX_LINKS distinct http(s) links in a message, as Discord embeds them: not inside
// code, not wrapped in <> (which suppresses the preview), with trailing punctuation left out. In temp.
link_urls :: (content: string) -> []string {
	out: [..]string;
	out.allocator = temp;
	code := false;
	i := 0;
	while i < content.count && out.count < MAX_LINKS {
		c := content[i];
		if c == #char "`" { code = !code; i += 1; continue; }
		rest := advance(content, i);
		if code || !(begins_with(rest, "https://") || begins_with(rest, "http://")) { i += 1; continue; }
		start := i;
		while i < content.count && content[i] > #char " " && content[i] != #char "<" && content[i] != #char ">" && content[i] != #char "`" i += 1;
		url := slice(content, start, i - start);
		while url.count && find_index_from_left(".,!?:;'\")]}*_~|", url[url.count - 1]) >= 0 url.count -= 1;
		suppressed := start > 0 && content[start - 1] == #char "<";
		if !suppressed && url.count <= 2048 array_add_if_unique(*out, url);
	}
	return out;
}

Url :: struct {
	tls: bool;
	host: string;      // As written, IPv6 in brackets.
	port: int;
	authority: string; // The Host header.
	path: string;      // With the query, without the fragment; bytes past ASCII percent-encoded.
}

parse_url :: (u: string) -> Url, bool {
	r: Url;
	rest: string;
	if begins_with(u, "https://") { r.tls, r.port, rest = true, 443, advance(u, 8); }
	else if begins_with(u, "http://") { r.port, rest = 80, advance(u, 7); }
	else return r, false;
	end := 0;
	while end < rest.count && rest[end] != #char "/" && rest[end] != #char "?" && rest[end] != #char "#" end += 1;
	r.authority = slice(rest, 0, end);
	path := advance(rest, end);
	hash := find_index_from_left(path, #char "#");
	if hash >= 0 path.count = hash;
	host := r.authority;
	colon := find_index_from_right(host, #char ":");
	if colon >= 0 && colon > find_index_from_right(host, #char "]") {
		port, ok, left := string_to_int(advance(host, colon + 1));
		if !ok || left.count || port <= 0 || port > 65535 return r, false;
		r.port = port;
		host.count = colon;
	}
	if !host || host.count > 253 return r, false;
	for cast([]u8) host if !(is_alnum(it) || it == #char "." || it == #char "-" || it == #char "[" || it == #char "]" || it == #char ":") return r, false;
	r.host = host;
	sb: String_Builder;
	sb.allocator = temp;
	if !path || path[0] != #char "/" append(*sb, "/");
	for cast([]u8) path {
		if it >= 0x80 print_to_builder(*sb, "\%%", formatInt(it, base = 16, minimum_digits = 2));
		else append(*sb, it);
	}
	r.path = builder_to_string(*sb,, temp);
	return r, true;
}

// unfurl fetches url, following up to MAX_REDIRECTS redirects, and reads the page's preview. The
// strings are in temp.
unfurl :: (s: *Server, url: string) -> Page, bool {
	at := url;
	for hop: 0..MAX_REDIRECTS {
		u, ok := parse_url(at);
		if !ok return .{}, false;
		host := u.host;
		if begins_with(host, "[") host = slice(host, 1, host.count - 2);
		tcp, derr := netio.dial_tcp(host, u.port, public_only = !s.unfurl_any_address);
		if derr != .None return .{}, false;
		stream := netio.tcp_stream(tcp);
		netio.set_timeout(stream, UNFURL_TIMEOUT_MS);
		if u.tls {
			session := tls.connect(stream, .{alpn = .["http/1.1"], server_name = host});
			if !session { netio.close(stream); return .{}, false; }
			stream = tls.stream(session);
		}
		h: http.H1_Conn;
		http.h1_init(*h, stream, .{max_body = MAX_PAGE},, temp);
		req := http.Request.{method = "GET", path = u.path, authority = u.authority,
			headers = .[.{"user-agent", UNFURL_AGENT}, .{"accept", "text/html"}, .{"accept-language", "en"}]};
		resp, herr := http.h1_round_trip(*h, req,, temp);
		http.h1_destroy(*h);
		if herr != .None return .{}, false;
		if resp.status >= 300 && resp.status < 400 {
			loc, has := http.header_get(resp.headers, "location");
			if !has return .{}, false;
			if begins_with(loc, "https://") || begins_with(loc, "http://") at = loc;
			else if begins_with(loc, "//") at = tprint("%:%", ifx u.tls then "https" else "http", loc);
			else if begins_with(loc, "/") at = tprint("%://%%", ifx u.tls then "https" else "http", u.authority, loc);
			else return .{}, false;
			continue;
		}
		type, _ := http.header_get(resp.headers, "content-type");
		if resp.status != 200 || !contains(to_lower_copy(type,, temp), "text/html") return .{}, false;
		page := scan_page(cast(string) resp.body);
		return page, page.title.count > 0 || page.description.count > 0;
	}
	return .{}, false;
}

// scan_page reads a preview from a page's head: OpenGraph first, then Twitter cards, then <title> and
// the description meta. One pass, each byte looked at a bounded number of times.
scan_page :: (html: string) -> Page {
	og_title, tw_title, title, og_desc, tw_desc, desc, site, theme: string;
	i := 0;
	n := html.count;
	at :: (word: string) -> bool #expand { return word_at(`html, `i, word); }
	find_from :: (word: string) -> int #expand { return skip_past(`html, *`i, word); }
	while i < n {
		lt := find_index_from_left(advance(html, i), #char "<");
		if lt < 0 break;
		i += lt + 1;
		if at("/head") || (at("body") && i + 4 < n && !is_alnum(html[i + 4])) break;
		if at("!--") { find_from("-->"); continue; }
		if at("script") || at("style") {
			close := ifx at("script") then "</script" else "</style";
			find_from(close);
			continue;
		}
		if at("title") && i + 5 < n && (html[i + 5] == #char ">" || html[i + 5] == #char " ") {
			gt := find_index_from_left(advance(html, i), #char ">");
			if gt < 0 break;
			i += gt + 1;
			start := i;
			end := find_from("</title");
			if end < 0 break;
			if !title title = slice(html, start, end - start);
			continue;
		}
		if !at("meta") || i + 4 >= n || !is_space(html[i + 4]) continue;
		i += 4;
		key, content: string;
		while i < n {
			while i < n && is_space(html[i]) i += 1;
			if i >= n || html[i] == #char ">" || html[i] == #char "/" break;
			start := i;
			while i < n && html[i] != #char "=" && html[i] != #char ">" && !is_space(html[i]) i += 1;
			name := slice(html, start, i - start);
			value: string;
			if i < n && html[i] == #char "=" {
				i += 1;
				if i < n && (html[i] == #char "\"" || html[i] == #char "'") {
					q := html[i];
					i += 1;
					start = i;
					while i < n && html[i] != q i += 1;
					value = slice(html, start, i - start);
					if i < n i += 1;
				} else {
					start = i;
					while i < n && html[i] != #char ">" && !is_space(html[i]) i += 1;
					value = slice(html, start, i - start);
				}
			}
			lname := to_lower_copy(name,, temp);
			if lname == "property" || lname == "name" key = to_lower_copy(value,, temp);
			else if lname == "content" content = value;
		}
		if key == {
			case "og:title";            if !og_title og_title = content;
			case "twitter:title";       if !tw_title tw_title = content;
			case "og:description";      if !og_desc og_desc = content;
			case "twitter:description"; if !tw_desc tw_desc = content;
			case "description";         if !desc desc = content;
			case "og:site_name";        if !site site = content;
			case "theme-color";         if !theme theme = content;
		}
	}
	p: Page;
	p.title = clean_text(ifx og_title then og_title else ifx tw_title then tw_title else title, 256);
	p.description = clean_text(ifx og_desc then og_desc else ifx tw_desc then tw_desc else desc, 350);
	p.site = clean_text(site, 256);
	if theme.count == 7 && theme[0] == #char "#" {
		v, ok, left := string_to_int(advance(theme, 1), 16);
		if ok && !left.count p.color = v;
	}
	return p;
}

word_at :: (html: string, i: int, word: string) -> bool {
	if i + word.count > html.count return false;
	for 0..word.count - 1 if to_lower(html[i + it]) != word[it] return false;
	return true;
}

// skip_past moves i past the next case-insensitive word and returns where it starts, or -1 at the end.
skip_past :: (html: string, i: *int, word: string) -> int {
	while i.* < html.count {
		if word_at(html, i.*, word) { start := i.*; i.* += word.count; return start; }
		i.* += 1;
	}
	return -1;
}

// clean_text decodes the common HTML entities, folds whitespace and control characters to single spaces,
// and cuts to max bytes on a UTF-8 boundary, with an ellipsis. In temp.
clean_text :: (s: string, max: int) -> string {
	sb: String_Builder;
	sb.allocator = temp;
	space := false;
	i := 0;
	while i < s.count {
		c := s[i];
		if c < #char " " || c == #char " " { space = true; i += 1; continue; }
		if space && builder_string_length(*sb) append(*sb, " ");
		space = false;
		if c != #char "&" { append(*sb, c); i += 1; continue; }
		semi := -1;
		for j: i + 1..min(i + 10, s.count - 1) if s[j] == #char ";" { semi = j; break; }
		if semi < 0 { append(*sb, c); i += 1; continue; }
		name := slice(s, i + 1, semi - i - 1);
		code := -1;
		if name == {
			case "amp"; code = #char "&";
			case "lt"; code = #char "<";
			case "gt"; code = #char ">";
			case "quot"; code = #char "\"";
			case "apos"; code = #char "'";
			case "nbsp"; code = #char " ";
			case;
				if name.count > 1 && name[0] == #char "#" {
					hexa := name[1] == #char "x" || name[1] == #char "X";
					v, ok, left := string_to_int(advance(name, ifx hexa then 2 else 1), ifx hexa then 16 else 10);
					if ok && !left.count && v >= 0x20 && v <= 0x10FFFF && !(v >= 0xD800 && v <= 0xDFFF) code = v;
				}
		}
		if code < 0 { append(*sb, c); i += 1; continue; }
		if code == #char " " space = true;
		else append(*sb, utf8_encode(cast(u32) code));
		i = semi + 1;
	}
	out := builder_to_string(*sb,, temp);
	if out.count <= max return out;
	cut := max - 3;
	while cut > 0 && (out[cut] & 0xC0) == 0x80 cut -= 1;
	return tprint("%...", slice(out, 0, cut));
}

utf8_encode :: (c: u32) -> string {
	b: [4]u8;
	n := 0;
	if c < 0x80 { b[0] = xx c; n = 1; }
	else if c < 0x800 { b[0] = xx (0xC0 | (c >> 6)); b[1] = xx (0x80 | (c & 0x3F)); n = 2; }
	else if c < 0x10000 { b[0] = xx (0xE0 | (c >> 12)); b[1] = xx (0x80 | ((c >> 6) & 0x3F)); b[2] = xx (0x80 | (c & 0x3F)); n = 3; }
	else { b[0] = xx (0xF0 | (c >> 18)); b[1] = xx (0x80 | ((c >> 12) & 0x3F)); b[2] = xx (0x80 | ((c >> 6) & 0x3F)); b[3] = xx (0x80 | (c & 0x3F)); n = 4; }
	return copy_string(string.{n, b.data},, temp);
}
