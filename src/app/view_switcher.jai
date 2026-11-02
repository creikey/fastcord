// Cmd+K quick switcher: fuzzy search over DMs, channels and servers.

Switcher :: struct {
	open: bool;
	editor: ui.Editor;
	sel: int;
	t: float32;
	max_query: int; // the longest query while open (quickswitcher_closed)
}

sw: Switcher;

Switch_Kind :: enum u8 {
	Channel;
	DM;
	Guild;
}

Switch_Item :: struct {
	kind: Switch_Kind;
	client: *dc.Client; // The connection it is on.
	id: dc.Snowflake; // channel or guild
	guild: dc.Snowflake;
	name: string;
	sub: string;
	score: float64; // the official search score (0 for an empty query)
}

// Subsequence match with bonuses for prefix and word starts; -1 = no match.
fuzzy_score :: (query: string, text: string) -> int {
	if query == "" { return 1; }
	q := to_lower_copy(query,, temp);
	t := to_lower_copy(text,, temp);
	if begins_with(t, q) { return 1000 - t.count; }
	i := find_index_from_left(t, q);
	if i >= 0 { return 500 - i; }
	score := 0;
	ti := 0;
	for qi: 0..q.count-1 {
		found := false;
		while ti < t.count {
			if t[ti] == q[qi] {
				score += ifx (ti == 0 || t[ti - 1] == #char " " || t[ti - 1] == #char "-") then 10 else 1;
				ti += 1;
				found = true;
				break;
			}
			ti += 1;
		}
		if !found { return -1; }
	}
	return score;
}

switcher_toggle :: () {
	if sw.open {
		switcher_close(switcher_items(trim(ui.editor_text(*sw.editor))));
		return;
	}
	sw.open = true;
	sw.t = 0;
	sw.sel = 0;
	sw.max_query = 0;
	ui.editor_set_text(*sw.editor, "");
}

// switcher_close: dismissed, or a result chosen (selected): the switcher's telemetry, then closed.
switcher_close :: (items: []Switch_Item = .[], selected := -1) {
	sw.open = false;
	if app.client == null { return; }
	// Only the selected connection's results go into its telemetry, so Discord never hears of a hosted
	// server's channels.
	res: [..]dc.Qs_Result;
	res.allocator = temp;
	picked := -1;
	for items {
		if it.client != app.client continue;
		if it_index == selected picked = res.count;
		r := array_add(*res);
		r.id, r.score = it.id, it.score;
		ch := dc.channel_get(store(), it.id);
		if it.kind == {
		case .DM;
			if ch != null && ch.kind == .DM && ch.recipient_ids.count > 0 { r.kind = .User; r.id = ch.recipient_ids[0]; } else { r.kind = .Group_Dm; }
		case .Channel;
			r.kind = .Text_Channel;
			if ch != null && (ch.kind == .Guild_Voice || ch.kind == .Guild_Stage_Voice) { r.kind = .Voice_Channel; }
			r.guild_id = it.guild;
		case .Guild;
			r.kind = .Guild;
		}
	}
	dc.analytics_quickswitcher_closed(app.client, app.view.guild, app.view.channel, trim(ui.editor_text(*sw.editor)), sw.max_query, res, picked);
}

// The results as the official QuickSwitcherStore's search ranks them (AutocompleteUtils queryUsers,
// queryGroupDMs, queryChannels, queryGuilds; traffic/CLIENT_RULES.md "Quick switcher"). Each kind is
// scored, sorted and cut to its best 5 (100 when only one kind matched), then all are sorted by score,
// equal scores in kind order: DMs, group DMs, text channels, voice channels, servers. An empty query
// lists DMs, then channels, all scored 0.
switcher_items :: (query: string) -> []Switch_Item {
	LIMIT :: 5;
	ONE_KIND_LIMIT :: 100;
	// the search's lists: 1:1 DMs, group DMs, channels (voice ones too), voice channels, servers
	lists: [5][..]Switch_Item;
	for * lists it.allocator = temp;
	// the best ONE_KIND_LIMIT, stable: an item goes after those that score the same
	add :: (list: *[..]Switch_Item, item: Switch_Item) {
		at := list.count;
		while at > 0 && list.*[at - 1].score < item.score { at -= 1; }
		if at >= ONE_KIND_LIMIT return;
		array_insert_at(list, item, at);
		if list.count > ONE_KIND_LIMIT list.count = ONE_KIND_LIMIT;
	}
	q := to_lower_copy(query,, temp);
	qid := dc.parse_snowflake(query); // a query that is an ID finds that result
	whole := Qs_Matcher.{q = q};
	// a channel name's matchers: each word, and first the whole query when it has several
	words: [..]Qs_Matcher;
	words.allocator = temp;
	if contains(q, " ") array_add(*words, .{q = q, full = true});
	for split(q, " ",, temp) if it array_add(*words, .{q = it});
	keep := app.client;
	defer app.client = keep;
	clients := connections();
	if !clients.count clients = .[app.client];
	for c: clients {
		app.client = c;
		s := store();
		if query && c && !c.cfg.hosted.host dc.frecency_load(c); // the search's loadIfNecessary
		b := qs_boosts(s);
		for cid: s.private_channels {
			ch := dc.channel_get(s, cid);
			if ch == null { continue; }
			name := dm_name(ch);
			item := Switch_Item.{kind = .DM, client = c, id = cid, name = name};
			if !query { add(*lists[0], item); continue; }
			if ch.kind == .DM && ch.recipient_ids.count > 0 {
				uid := ch.recipient_ids[0];
				u := dc.user_get(s, uid);
				if u == null || uid == s.me { continue; }
				tier := qs_user_tier(q, u.username, dc.friend_nickname(s, uid), u.global_name);
				if uid == qid tier = 10;
				if !tier { continue; }
				r := table_find_pointer(*s.relationships, uid);
				// a friend +0.2, a DM's user +0.1
				item.score = 1000 * tier * (qs_boost(*b, .User, uid) + ifx r && r.kind == .Friend then 0.3 else 0.1);
				add(*lists[0], item);
			} else {
				tier := qs_match(to_lower_copy(name,, temp), whole);
				for ch.recipient_ids {
					u := dc.user_get(s, it);
					if u == null { continue; }
					for n: string.[u.username, u.global_name, dc.friend_nickname(s, it)] if n tier = max(tier, min(qs_match(to_lower_copy(n,, temp), whole), 5));
				}
				if !tier { continue; }
				item.score = 1000 * tier * qs_boost(*b, .Group_Dm, cid);
				add(*lists[1], item);
			}
		}
		for gid: guild_order() {
			g := dc.guild_get(s, gid);
			if g == null { continue; }
			if query && !(c == keep && gid == app.view.guild) { // the current server is left out
				tier := ifx gid == qid then 10.0 else qs_match(to_lower_copy(g.name,, temp), whole);
				if tier { add(*lists[4], .{kind = .Guild, client = c, id = gid, name = g.name, score = 1000 * tier * qs_boost(*b, .Guild, gid)}); }
			}
			for cid: dc.guild_channels_sorted(s, gid) {
				ch := dc.channel_get(s, cid);
				if ch == null || ch.kind == .Guild_Category { continue; }
				item := Switch_Item.{kind = .Channel, client = c, id = cid, guild = gid, name = ch.name, sub = g.name};
				if !query { add(*lists[2], item); continue; }
				tier := qs_channel_tier(s, ch, g, cid == qid, words);
				if !tier { continue; }
				voice := ch.kind == .Guild_Voice || ch.kind == .Guild_Stage_Voice;
				if voice && !dc.has_permission(dc.channel_permissions(s, cid), dc.PERM_VIEW_CHANNEL | dc.PERM_CONNECT) { continue; }
				_, used := table_find(*b.frecency, cid);
				// a channel used before scores 3 more, up to 10 (from 7 and up) or 7
				raise :: (tier: float64, used: float64) -> float64 { return min(tier + 3 * min(used, 1.0), ifx tier >= 7 then 10.0 else 7.0); }
				// the channel search ranks a voice channel one lower; the voice search doesn't
				item.score = 1000 * raise(ifx voice then max(tier - 1, 0.5) else tier, used) * qs_boost(*b, .Text_Channel, cid);
				add(*lists[2], item);
				if voice {
					item.score = 1000 * raise(tier, used) * qs_boost(*b, .Voice_Channel, cid);
					add(*lists[3], item);
				}
			}
		}
	}
	kinds := 0;
	for lists if it.count kinds += 1;
	out: [..]Switch_Item;
	out.allocator = temp;
	for list, k: lists {
		for list {
			if query && kinds > 1 && it_index >= LIMIT break;
			// a voice channel the channel search kept stays as it ranked it there
			dup := false;
			if k == 3 for o: out if o.id == it.id && o.client == it.client { dup = true; break; }
			if !dup add(*out, it);
		}
	}
	return out;
}

// A query (lower case) as AutocompleteUtils matches it. full: a channel search's whole query, whose
// first space also matches a "-".
Qs_Matcher :: struct {
	q: string;
	full: bool;
}

// qs_match: a name's (lower case) match tier: 10 the query itself, 7 starts with it, 5 contains it,
// 3 contains each of its words (split at spaces and commas), 1 has its letters in order (fuzzy).
qs_match :: (text: string, m: Qs_Matcher, fuzzy := true) -> float64 {
	at :: (text: string, i: int, m: Qs_Matcher) -> bool {
		if text.count - i < m.q.count return false;
		dash := m.full;
		for c, j: cast([]u8) m.q {
			t := text[i + j];
			if c == #char " " && dash {
				dash = false;
				if t == #char "-" continue;
			}
			if t != c return false;
		}
		return true;
	}
	if at(text, 0, m) return ifx text == m.q then 10.0 else 7.0;
	for i: 1..text.count - m.q.count if at(text, i, m) return 5;
	each := true;
	for split(m.q, " ",, temp) for w: split(it, ",",, temp) if w && !contains(text, w) { each = false; break; }
	if each return 3;
	if fuzzy && qs_in_order(m.q, text) return 1;
	return 0;
}

// qs_in_order: needle's characters appear in text in order (the fuzzysearch package).
qs_in_order :: (needle: string, text: string) -> bool {
	if needle.count > text.count return false;
	if needle.count == text.count return needle == text;
	j := 0;
	for i: 0..needle.count - 1 {
		while j < text.count && text[j] != needle[i] { j += 1; }
		if j == text.count return false;
		j += 1;
	}
	return true;
}

// qs_user_tier: a DM's user: 10 when a name (username, friend nickname, display name) starts with the
// query, 1 when one has its letters in order.
qs_user_tier :: (q: string, names: ..string) -> float64 {
	for names if it && begins_with(to_lower_copy(it,, temp), q) return 10;
	for names if it && qs_in_order(q, to_lower_copy(it,, temp)) return 1;
	return 0;
}

// qs_channel_tier: queryChannels' match of a channel name: the best word's tier, that word used up
// (the whole query uses up all). Words left over may match the server or category name for half their
// tier, up to 6 in all; a word still unused (the whole query aside) is no match.
qs_channel_tier :: (s: *dc.Store, ch: *dc.Channel, g: *dc.Guild, id: bool, words: []Qs_Matcher) -> float64 {
	left: [..]Qs_Matcher;
	left.allocator = temp;
	array_add(*left, ..words);
	best :: (text: string, left: *[..]Qs_Matcher, fuzzy: bool) -> float64 {
		top, at := cast(float64) 0, -1;
		for left.* {
			t := qs_match(text, it, fuzzy);
			if t > top { top, at = t, it_index; }
		}
		if at < 0 return 0;
		if left.*[at].full { left.count = 0; } else { array_ordered_remove_by_index(left, at); }
		return top;
	}
	tier := ifx id then 10.0 else best(to_lower_copy(ch.name,, temp), *left, true);
	if !tier return 0;
	if left.count {
		parent := dc.channel_get(s, ch.parent_id);
		for n: string.[g.name, ifx parent then parent.name else ""] if n tier += 0.5 * best(to_lower_copy(n,, temp), *left, false);
		tier = min(tier, 6);
	}
	if left.count > 1 || (left.count == 1 && !left[0].full && !id) return 0;
	return tier;
}

// FrecencyStore's guild and channel frecency, and the search's boosters by dc.Qs_Kind: 1 + frecency /
// the top one's, for the 100 most frecent (a DM's under its user).
Qs_Boosts :: struct {
	frecency: Table(dc.Snowflake, float64);
	boost: [5]Table(dc.Snowflake, float64);
}

qs_boosts :: (s: *dc.Store) -> Qs_Boosts {
	b: Qs_Boosts;
	b.frecency.allocator = temp;
	for * b.boost it.allocator = temp;
	Used :: struct { id: dc.Snowflake; frecency: float64; kind: int; } // kind -1: none (a category)
	used: [..]Used;
	used.allocator = temp;
	now := dc.now_ms();
	for s.frecency.history[dc.Frecency_Kind.Guild_Channel] {
		// a use's weight by its age in days: 0 100, 1 70, 2-3 50, 4-6 30, older 10
		score := 0;
		for u: it.recent_uses {
			if it_index >= 10 break;
			d := (now - u) / 86_400_000;
			score += ifx d < 0 then 1 else ifx d < 1 then 100 else ifx d < 2 then 70 else ifx d < 4 then 50 else ifx d < 7 then 30 else 10;
		}
		if !score continue;
		f := ceil(cast(float64) it.total_uses * score / it.recent_uses.count);
		id := dc.parse_snowflake(it.key);
		table_set(*b.frecency, id, f);
		kind := -1;
		ch := dc.channel_get(s, id);
		if dc.guild_get(s, id) {
			kind = xx dc.Qs_Kind.Guild;
		} else if ch == null {
			continue;
		} else if ch.kind == .DM && ch.recipient_ids.count > 0 {
			kind, id = xx dc.Qs_Kind.User, ch.recipient_ids[0];
		} else if ch.kind == .Group_DM {
			kind = xx dc.Qs_Kind.Group_Dm;
		} else if ch.kind == .Guild_Voice || ch.kind == .Guild_Stage_Voice {
			kind = xx dc.Qs_Kind.Voice_Channel;
		} else if ch.kind != .Guild_Category {
			kind = xx dc.Qs_Kind.Text_Channel;
		}
		at := used.count;
		while at > 0 && used[at - 1].frecency < f { at -= 1; }
		array_insert_at(*used, .{id, f, kind}, at);
	}
	if used.count > 100 used.count = 100;
	for used if it.kind >= 0 table_set(*b.boost[it.kind], it.id, 1 + it.frecency / used[0].frecency);
	return b;
}

qs_boost :: (b: *Qs_Boosts, kind: dc.Qs_Kind, id: dc.Snowflake) -> float64 {
	found, v := table_find(*b.boost[kind], id);
	return ifx found then v else 1;
}

switcher_activate :: (items: []Switch_Item, index: int) {
	switcher_close(items, index);
	item := items[index];
	app.client = item.client;
	if item.kind == {
	case .DM;
		select_channel(0, item.id);
	case .Channel;
		select_channel(item.guild, item.id);
	case .Guild;
		select_guild(item.id);
	}
}

quick_switcher :: () {
	ui.animate(*sw.t, 1, 30);
	scrim := ui.box("sw_scrim", .Draw_Background | .Clickable | .Floating_X | .Floating_Y | .Overlay);
	scrim.semantic_size = .[ui.px(app.ui.window.x), ui.px(app.ui.window.y)];
	scrim.style.bg = .{0, 0, 0, 0.7 * sw.t};
	query := trim(ui.editor_text(*sw.editor));
	items := switcher_items(query);
	sw.max_query = max(sw.max_query, query.count);
	if ui.signal(scrim).clicked {
		switcher_close(items);
		return;
	}
	shown := min(items.count, 12); // the rows drawn (the telemetry counts all)
	sw.sel = clamp(sw.sel, 0, max(shown - 1, 0));
	for * e: app.ui.events {
		if e.kind != .Key_Down || e.consumed { continue; }
		if e.key == {
		case .Down;
			sw.sel = min(sw.sel + 1, shown - 1);
			e.consumed = true;
		case .Up;
			sw.sel = max(sw.sel - 1, 0);
			e.consumed = true;
		case .Escape;
			switcher_close(items);
			e.consumed = true;
		}
	}
	W :: 570;
	box := ui.box("switcher", .Draw_Background | .Draw_Shadow | .Floating_X | .Floating_Y | .Overlay | .Clickable);
	box.semantic_size = .[ui.px(W), ui.children()];
	box.fixed_pos = .{(app.ui.window.x - W) / 2, app.ui.window.y * 0.2 - (1 - sw.t) * 8};
	box.opacity = sw.t;
	box.layout_axis = .Y;
	box.style.bg = T("--modal-background");
	box.style.radius = all4(8);
	box.style.shadow_color = .{0, 0, 0, 0.3};
	box.style.shadow_blur = 24;
	ui.signal(box);
	{ ui.parent(box); defer ui.pop_parent();
		spacer(.Y, 20);
		r := row("inrow");
		r.semantic_size = .[ui.pct(1), ui.px(70)];
		{ ui.parent(r); defer ui.pop_parent();
			spacer(.X, 20);
			field := row("field", .Draw_Background);
			field.semantic_size = .[ui.fill(), ui.px(70)];
			field.style.bg = T("--input-background-default");
			field.style.radius = all4(4);
			{ ui.parent(field); defer ui.pop_parent();
				spacer(.X, 12);
				res := text_field("q", *sw.editor, L("Where would you like to go?"), true, 24, 30);
				if res == .Submit && items.count > 0 { switcher_activate(items, sw.sel); }
				if res == .Changed { sw.sel = 0; }
				spacer(.X, 12);
			}
			spacer(.X, 20);
		}
		spacer(.Y, 12);
		for item, i: array_view(items, 0, shown) {
			ir := row(tprint("it%", i), .Clickable | .Draw_Background);
			ir.semantic_size = .[ui.pct(1), ui.px(34)];
			sig := ui.signal(ir);
			if sig.hovering && app.ui.mouse != app.ui.mouse_prev { sw.sel = i; }
			sel := i == sw.sel;
			if sel { ir.style.bg = T("--background-mod-normal"); }
			if sig.clicked { switcher_activate(items, i); }
			{ ui.parent(ir); defer ui.pop_parent();
				keep := app.client;
				app.client = item.client;
				defer app.client = keep;
				spacer(.X, 28);
				if item.kind == {
				case .DM;
					ch := dc.channel_get(store(), item.id);
					if ch != null && ch.kind == .DM && ch.recipient_ids.count > 0 { avatar_box("av", ch.recipient_ids[0], 20); } else if ch != null { group_dm_icon("ic", ch, 20); }
				case .Channel;
					ch := dc.channel_get(store(), item.id);
					icon("ic", ifx ch != null then channel_icon_name(ch) else "text", 20, T("--interactive-icon-default"));
				case .Guild;
					icon("ic", "server", 20, T("--interactive-icon-default"));
				}
				spacer(.X, 8);
				label(item.name, .Medium, 16, ifx sel then T("--interactive-text-active") else T("--interactive-text-default"), 20);
				if item.sub != "" {
					filler(.X);
					label(item.sub, .Semibold, 12, T("--text-muted"), 16);
				}
				spacer(.X, 28);
			}
		}
		spacer(.Y, 20);
	}
}

