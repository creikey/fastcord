// Webhook posts in other services' formats, as Discord takes them: /api/webhooks/{id}/{token}/github for
// GitHub's repository webhooks and /slack for Slack-style tools. Each becomes a post in Discord's own shape
// ({username, content, embeds}) that the webhook route then checks and sends like any other.

// github_post turns a GitHub delivery (its X-GitHub-Event) into a post, as Discord's /github does; Nil for
// events Discord doesn't show (ping among them).
github_post :: (event: string, p: etf.Value) -> etf.Value {
	if p.kind != .Map return .{};
	repo := str(p, "repository", "full_name");
	action := str(p, "action");
	title, description, url: string;
	color := 0;
	if event == {
	case "push";
		commits, _ := etf.map_get(p.map, "commits");
		if commits.kind != .List || !commits.list.count return .{};
		branch := str(p, "ref");
		if begins_with(branch, "refs/heads/") branch = advance(branch, "refs/heads/".count);
		n := commits.list.count;
		title = tprint("[%:%] % new commit%", repo, branch, n, ifx n == 1 then "" else "s");
		url = str(p, "compare");
		sb: String_Builder;
		sb.allocator = temp;
		for commits.list {
			if it_index == 5 break; // Discord lists the first five.
			id := str(it, "id");
			message := str(it, "message");
			newline := find_index_from_left(message, #char "\n");
			if newline >= 0 message.count = newline;
			print_to_builder(*sb, "%1[`%2`](%3) %4 - %5", ifx it_index then "\n" else "", slice(id, 0, 7), str(it, "url"), clip(message, 50, false), str(it, "author", "name"));
		}
		description = builder_to_string(*sb,, temp);
		color = 0x7289DA;
	case "pull_request";
		if action != "opened" && action != "closed" && action != "reopened" return .{};
		merged := action == "closed" && str(p, "pull_request", "merged_at") != "";
		title = tprint("[%] Pull request %: #% %", repo, ifx merged then "merged" else action, int_field(p, "pull_request", "number"), str(p, "pull_request", "title"));
		url = str(p, "pull_request", "html_url");
		if action == "opened" description = str(p, "pull_request", "body");
		color = ifx action == "closed" then 0 else 0x009800;
	case "issues";
		if action != "opened" && action != "closed" && action != "reopened" return .{};
		title = tprint("[%] Issue %: #% %", repo, action, int_field(p, "issue", "number"), str(p, "issue", "title"));
		url = str(p, "issue", "html_url");
		if action == "opened" description = str(p, "issue", "body");
		color = ifx action == "opened" then 0xEB6420 else 0;
	case "issue_comment";
		if action != "created" return .{};
		title = tprint("[%] New comment on issue #%: %", repo, int_field(p, "issue", "number"), str(p, "issue", "title"));
		url = str(p, "comment", "html_url");
		description = str(p, "comment", "body");
		color = 0xE68D60;
	case "release";
		if action != "published" return .{};
		title = tprint("[%] New release published: %", repo, str(p, "release", "tag_name"));
		url = str(p, "release", "html_url");
	case "create"; #through;
	case "delete";
		title = tprint("[%] % % %", repo, ifx str(p, "ref_type") == "tag" then "Tag" else "Branch", ifx event == "create" then "created:" else "deleted:", str(p, "ref"));
	case "fork";
		title = tprint("[%] Fork created: %", repo, str(p, "forkee", "full_name"));
		url = str(p, "forkee", "html_url");
	case "watch";
		title = tprint("[%] New star added", repo);
		url = str(p, "repository", "html_url");
	case;
		return .{};
	}
	embed := etf.map_builder(5,, temp);
	etf.map_put(*embed, "title", etf.vstring(clip(title, 256, false)));
	if description etf.map_put(*embed, "description", etf.vstring(clip(description, 500, true)));
	if begins_with(url, "https://") etf.map_put(*embed, "url", etf.vstring(url));
	etf.map_put(*embed, "color", etf.vint(color));
	sender := str(p, "sender", "login");
	if sender {
		author := etf.map_builder(1,, temp);
		etf.map_put(*author, "name", etf.vstring(clip(sender, 256, false)));
		etf.map_put(*embed, "author", etf.vmap(etf.map_done(*author)));
	}
	return post("GitHub", "", etf.vmap(etf.map_done(*embed)));
}

// slack_post turns a Slack-style payload {text, username, attachments: [{title, title_link, text, pretext,
// color, fields: [{title, value, short}], author_name, footer}]} into a post; Slack's <url|label> links
// become Markdown ones.
slack_post :: (p: etf.Value) -> etf.Value {
	if p.kind != .Map return .{};
	attachments, _ := etf.map_get(p.map, "attachments");
	embeds: [..]etf.Value;
	embeds.allocator = temp;
	if attachments.kind == .List for a: attachments.list {
		if a.kind != .Map || embeds.count == MAX_EMBEDS continue;
		e := etf.map_builder(7,, temp);
		put :: (e: *etf.Map_Builder, key: string, text: string, max: int, lines := false) {
			if text etf.map_put(e, key, etf.vstring(clip(slack_links(text), max, lines)));
		}
		put(*e, "title", str(a, "title"), 256);
		text := str(a, "text");
		if !text text = str(a, "pretext");
		put(*e, "description", text, 4096, true);
		link := str(a, "title_link");
		if begins_with(link, "https://") || begins_with(link, "http://") etf.map_put(*e, "url", etf.vstring(clip(link, 2048, false)));
		hex := str(a, "color");
		if begins_with(hex, "#") hex = advance(hex, 1);
		color, ok, rest := string_to_int(hex, 16);
		if hex.count == 6 && ok && !rest etf.map_put(*e, "color", etf.vint(color));
		for key: string.["author_name", "footer"] {
			v := str(a, key);
			if !v continue;
			sub := etf.map_builder(1,, temp);
			etf.map_put(*sub, ifx key == "footer" then "text" else "name", etf.vstring(clip(v, 256, false)));
			etf.map_put(*e, ifx key == "footer" then "footer" else "author", etf.vmap(etf.map_done(*sub)));
		}
		fields_v, _ := etf.map_get(a.map, "fields");
		fields: [..]etf.Value;
		fields.allocator = temp;
		if fields_v.kind == .List for f: fields_v.list {
			if fields.count == 25 || !str(f, "title") break;
			m := etf.map_builder(3,, temp);
			etf.map_put(*m, "name", etf.vstring(clip(slack_links(str(f, "title")), 256, false)));
			etf.map_put(*m, "value", etf.vstring(clip(slack_links(ifx str(f, "value") then str(f, "value") else "-"), 1024, true)));
			short, _ := etf.map_get(f.map, "short");
			etf.map_put(*m, "inline", etf.vbool(short.kind == .Bool && short.b));
			array_add(*fields, etf.vmap(etf.map_done(*m)));
		}
		if fields.count etf.map_put(*e, "fields", etf.vlist(fields));
		array_add(*embeds, etf.vmap(etf.map_done(*e)));
	}
	m := etf.map_builder(3,, temp);
	text := str(p, "text");
	if text etf.map_put(*m, "content", etf.vstring(clip(slack_links(text), MAX_CONTENT, true)));
	name := str(p, "username");
	if name etf.map_put(*m, "username", etf.vstring(clip(name, 80, false)));
	if embeds.count etf.map_put(*m, "embeds", etf.vlist(embeds));
	return etf.vmap(etf.map_done(*m));
}

#scope_file

post :: (username: string, content: string, embed: etf.Value) -> etf.Value {
	list := NewArray(1, etf.Value,, temp);
	list[0] = embed;
	m := etf.map_builder(3,, temp);
	etf.map_put(*m, "username", etf.vstring(username));
	if content etf.map_put(*m, "content", etf.vstring(content));
	etf.map_put(*m, "embeds", etf.vlist(list));
	return etf.vmap(etf.map_done(*m));
}

// str follows keys through nested objects to a string; "" when any step is missing or not that kind.
str :: (root: etf.Value, keys: ..string) -> string {
	v := root;
	for keys {
		if v.kind != .Map return "";
		v, _ = etf.map_get(v.map, it);
	}
	return ifx v.kind == .String then v.s else "";
}

int_field :: (root: etf.Value, keys: ..string) -> s64 {
	v := root;
	for keys {
		if v.kind != .Map return 0;
		v, _ = etf.map_get(v.map, it);
	}
	return ifx v.kind == .Int then v.i else 0;
}

// clip cuts s to at most max bytes (so at most max UTF-16 units) on a character boundary, with an ellipsis,
// and turns control characters (but newlines, where lines is set) into spaces, so text_ok takes it. In temp.
clip :: (s: string, max: int, lines: bool) -> string {
	out := copy_string(s,, temp);
	for 0..out.count - 1 if out[it] < #char " " && !(lines && out[it] == #char "\n") out[it] = #char " ";
	if out.count <= max return out;
	cut := max - 3;
	while cut > 0 && (out[cut] & 0xC0) == 0x80 cut -= 1;
	return tprint("%…", slice(out, 0, cut));
}

// slack_links rewrites Slack's <url|label> and <url> as Markdown links and bare URLs, in one pass: text is
// copied as it comes, and a '>' closing a URL opened by the last '<' rewrites what followed that '<'.
slack_links :: (s: string) -> string {
	out: [..]u8;
	out.allocator = temp;
	open, mark := -1, 0;
	for c, i: cast([]u8) s {
		if c == #char "<" { open, mark = i, out.count; }
		if c != #char ">" || open < 0 { array_add(*out, c); continue; }
		inner := slice(s, open + 1, i - open - 1);
		open = -1;
		if !begins_with(inner, "http://") && !begins_with(inner, "https://") { array_add(*out, c); continue; }
		out.count = mark;
		bar := find_index_from_left(inner, #char "|");
		link := ifx bar >= 0 then tprint("[%](%)", advance(inner, bar + 1), slice(inner, 0, bar)) else inner;
		array_add(*out, ..cast([]u8) link);
	}
	return cast(string) out;
}
