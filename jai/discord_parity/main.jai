A_ID :: cast(discord.Snowflake)(1546819257420087346);
B_ID :: cast(discord.Snowflake)(1564202918369042442);
B_NAME :: "bobbles_2345";
TGUILD :: cast(discord.Snowflake)(1564227669971832975);
TTEXT :: cast(discord.Snowflake)(1564405699197407414); // #general, recreated 2026-10-26
TVOICE :: cast(discord.Snowflake)(1564227670806364345);
DM_AB :: cast(discord.Snowflake)(1564228964451356713);
VIEW_W :: 1280;
VIEW_H :: 720;

Acct :: struct {
	name: string;
	token: string;
	state: string;
	c: *discord.Client;
	events: [..]string; // received dispatch names (cursor-based waits)
	cursor: int;
}

rec: *discord.Recorder;
scenario: string;
// session mode: one long-lived client per account performs every scenario in
// turn, like one person using the app; "reload" only happens at launch.
session_mode: bool;
reloads: [2]int;

// start_route: the route the official instance reopened on at the n-th reload
// of this account, read from traffic/<scenario>.jsonl (first messages?limit=
// page and lurker PUT after each ws_open).
// fixture_fast_connect: whether the official n-th start of acct identified
// through the native fast connect (before HELLO) or from the web app after
// HELLO (gateway_connect_reasons "AppSkeleton"); both happen in the captures.
fixture_fast_connect :: (acct: string, n: int) -> bool {
	data, err := os.read_entire_file(fmt.tprintf("traffic/%s.jsonl", scenario), temp);
	if err != null { return true; }
	text := as_string(data);
	seen := 0;
	while true { line, __ok1 := strings.split_lines_iterator(*text); if !__ok1 break;
		if !strings.contains(line, "\"op\":2,") || !strings.contains(line, "\"ws_send\"") { continue; }
		v, jerr := etf.from_json(line, temp);
		if jerr != .None { continue; }
		m := discord.vmap(v);
		a := discord.fstr(m, "acct");
		if a == "" { a = "a"; }
		if a != acct { continue; }
		if seen == n {
			fc, _ := discord.vget(discord.fmap(discord.fmap(m, "d"), "properties"), "is_fast_connect").b, discord.vget(discord.fmap(discord.fmap(m, "d"), "properties"), "is_fast_connect").kind == .Bool;
			return fc;
		}
		seen += 1;
	}
	return true;
}

start_route :: (acct: string, n: int) -> discord.Snowflake, discord.Snowflake {
	guild: discord.Snowflake;
	channel: discord.Snowflake;
	data, err := os.read_entire_file(fmt.tprintf("traffic/%s.jsonl", scenario), temp);
	if err != null { return 0, 0; }
	text := as_string(data);
	opens := -1;
	ready_seen := false;
	route_done := false;
	while true { line, __ok2 := strings.split_lines_iterator(*text); if !__ok2 break;
		// the start route's page is requested right at READY; later pages are clicks
		if ready_seen && channel == 0 { route_done = true; }
		v, jerr := etf.from_json(line, temp);
		if jerr != .None { continue; }
		m := discord.vmap(v);
		a := discord.fstr(m, "acct");
		if a == "" { a = "a"; }
		if a != acct { continue; }
		k := discord.fstr(m, "k");
		if k == "mark" && opens == n && n >= 0 && (guild != 0 || channel != 0 || true) {
			// the route is what the client reopened on: stop at the next step
			name := discord.fstr(m, "name");
			if name != "setup" && name != "setup_b" { break; }
		}
		if k == "ws_recv" && opens == n && discord.fstr(m, "ev") == "READY_SUPPLEMENTAL" {
			ready_seen = true;
		}
		if k == "ws_open" {
			opens += 1;
			if opens > n { break; }
			continue;
		}
		if opens != n || k != "req" { continue; }
		url := discord.fstr(m, "url");
		{ i := strings.index(url, "/guilds/");
		if i >= 0 && strings.contains(url, "lurker=true") {
			rest := sub_from(url, i + 8);
			guild = discord.parse_snowflake(sub(rest, 0, strings.index_byte(rest, #char "/")));
		} }
		{ i := strings.index(url, "/channels/");
		if i >= 0 && strings.contains(url, "/messages?limit=") && channel == 0 && !route_done {
			rest := sub_from(url, i + 10);
			channel = discord.parse_snowflake(sub(rest, 0, strings.index_byte(rest, #char "/")));
		} }
	}
	return guild, channel;
}
accts: [2]Acct;
cur: *Acct;

main :: () {
	args := get_command_line_arguments();
	if len(args) < 2 {
		fmt.eprintln("usage: parity <scenario> [out.jsonl] | parity session [scenario...]");
		os.exit(2);
	}
	if args[1] == "session" {
		session_report(sub_from(args, 2));
		return;
	}
	name := args[1];
	scenario = name;
	out := ifx len(args) > 2 then args[2] else fmt.tprintf(".secrets/raw/ours_%s.jsonl", name);
	accts[0] = .{name = "a", token = token_a(), state = ".secrets/parity-state-a"};
	accts[1] = .{name = "b", token = token_b(), state = ".secrets/parity-state-b"};
	if accts[0].token == "" {
		fmt.eprintln("no token for A");
		os.exit(1);
	}
	ok: bool;
	rec, ok = discord.recorder_open(out);
	if !ok {
		fmt.eprintln("cannot open", out);
		os.exit(1);
	}
	cur = *accts[0];
	ran := run(name);
	if ran { settle(2000, 15000); }
	for * a: accts { if a.c != null { stop(a); } }
	discord.recorder_close(rec);
	if !ran {
		fmt.eprintln("unknown or failed scenario:", name);
		os.exit(1);
	}
	fmt.println(name, "->", out);
}

// ---- tokens (never printed) ----

token_a :: () -> string {
	data, err := os.read_entire_file(".secrets/raw/gw_a.jsonl", context.allocator);
	if err != null { return ""; }
	text := as_string(data);
	while true { line, __ok3 := strings.split_lines_iterator(*text); if !__ok3 break;
		if !strings.contains(line, "\"op\":2") && !strings.contains(line, "\"op\": 2") { continue; }
		v, jerr := etf.from_json(line);
		if jerr != .None { continue; }
		e := discord.fmap(discord.vmap(v), "etf");
		if discord.fint(e, "op") == 2 { return discord.fstr(discord.fmap(e, "d"), "token"); }
	}
	return "";
}

token_b :: () -> string {
	f, err := os.open(".secrets/raw/coldstart_b.jsonl");
	if err != null { return ""; }
	defer os.close(f);
	buf: [1 << 16]u8;
	carry := make_dynamic(u8, 0, 0);
	while true {
		n, rerr := os.read(f, view(buf));
		if n <= 0 || rerr != null { break; }
		append(*carry, ..sub(buf, 0, n));
		s := as_string(view(carry));
		{ i := strings.index(s, "\"Authorization\": \"");
		if i >= 0 {
			rest := sub_from(s, i + len("\"Authorization\": \""));
			{ j := strings.index_byte(rest, 34);
			if j >= 0 { return clone(sub(rest, 0, j)); } }
		} }
		{ i := strings.index(s, "\"Authorization\":\"");
		if i >= 0 {
			rest := sub_from(s, i + len("\"Authorization\":\""));
			{ j := strings.index_byte(rest, 34);
			if j >= 0 { return clone(sub(rest, 0, j)); } }
		} }
		if len(carry) > (1 << 20) { remove_range(*carry, 0, len(carry) - 4096); }
	}
	return "";
}

// ---- driving ----

use :: (n: string) {cur = ifx n == "a" then *accts[0] else *accts[1];}

// tools/capture records every scenario mark on account A's stream.
mark :: (n: string) {discord.recorder_mark(rec, "a", n);}

// reload: the app restarts on the same profile (cookies, alt-svc, heartbeat
// session persisted) and reopens on the route the official instance was on.
reload :: () {
	a := cur;
	if session_mode && a.c != null {
		human(1500, 4000); // back to the app
		return;
	}
	idx := ifx a.name == "a" then 0 else 1;
	guild, channel := start_route(a.name, reloads[idx]);
	fast := fixture_fast_connect(a.name, reloads[idx]);
	reloads[idx] += 1;
	if a.c != null { stop(a); }
	clear(*a.events);
	a.cursor = 0;
	a.c = discord.client_create(discord.Config.{token = a.token, state_dir = a.state, initial_guild_id = guild, initial_channel_id = channel, disable_fast_connect = !fast});
	discord.recorder_attach(rec, a.c, a.name);
	// recorder_attach owns observer_data; route gateway dispatch names to us via the recv hook data
	a.c.user_data = a;
	a.c.on_dispatch = (user: *void, name: string) {
		acct := cast(*Acct)user;
		// The capture instances lose window focus once loaded: AppStateStore
		// reports "unfocused" from READY on (QoS stays foregrounded).
		if name == "READY" { discord.identity_set_app_state(*acct.c.id, .Unfocused); }
		locks.lock(*names_mu);
		append(*acct.events, clone(name));
		locks.unlock(*names_mu);
	};
	// without native fast connect the app's IDENTIFY carries client_app_state:
	// the capture windows are already unfocused then
	if !fast { discord.identity_set_app_state(*a.c.id, .Unfocused); }
	discord.client_set_viewport(a.c, VIEW_W, VIEW_H);
	discord.client_set_accessibility(a.c, discord.A11Y_PREFERS_COLOR_SCHEME_LIGHT);
	discord.client_start(a.c);
	wait_gw("READY", 45000);
	settle(2500, 30000);
}

names_mu: locks.Mutex;

stop :: (a: *Acct) {
	discord.client_destroy(a.c);
	a.c = null;
}

pump :: (ms: int) {
	deadline := time.tick_now();
	while time.tick_since(deadline) < cast(time.Duration)(ms) * time.Millisecond {
		for * a: accts { if a.c != null { discord.client_poll(a.c); } }
		time.sleep(16 * time.Millisecond);
	}
}

human :: (lo: int, hi: int) {pump(lo + cast(int)(rand.uint32_() % cast(u32)(hi - lo + 1)));}

// click: tools/capture's mouse move (4-25 steps of 8-22 ms, then 80-220 ms),
// the click, then 500-1100 ms.
click :: () {
	human(80, 400);
	human(80, 220);
	human(500, 1100);
}

// wait_for: DOM polling every 250 ms (half a period on average).
wait_for :: () {pump(125 + cast(int)(rand.uint32_() % 250));}
pause :: () {human(700, 1600);}

// settle: like tools/capture — wait until no network event for quiet_ms (max max_ms).
settle :: (quiet_ms: int, max_ms := 20000) {
	start := time.tick_now();
	while time.tick_since(start) < cast(time.Duration)(max_ms) * time.Millisecond {
		if discord.now_ms() - discord.recorder_last_net(rec) >= cast(s64)(quiet_ms) { return; }
		pump(200);
	}
}

// wait_gw: until a dispatch arrives on the current account since the last action.
wait_gw :: (ev: string, timeout_ms := 15000) -> bool {
	deadline := time.tick_now();
	while time.tick_since(deadline) < cast(time.Duration)(timeout_ms) * time.Millisecond {
		for * a: accts { if a.c != null { discord.client_poll(a.c); } }
		locks.lock(*names_mu);
		for i: cur.cursor..len(cur.events)-1 {
			if cur.events[i] == ev {
				cur.cursor = i + 1;
				locks.unlock(*names_mu);
				return true;
			}
		}
		locks.unlock(*names_mu);
		time.sleep(16 * time.Millisecond);
	}
	fmt.eprintln("timeout waiting for", ev);
	return false;
}

action :: () {
	locks.lock(*names_mu);
	cur.cursor = len(cur.events);
	locks.unlock(*names_mu);
}

typed :: (channel: discord.Snowflake, text: string) {
	action();
	for _: text {
		if channel != 0 { discord.typing_keystroke(cur.c, channel); }
		human(20, 50);
		human(60, 170);
	}
	human(300, 700);
}

// picker_typed: typing a search into the emoji picker (search_started). The
// results' search_result_viewed needs the app's emoji database (its result
// counts), so this driver does not send it: expect it missing in the diff.
picker_typed :: (query: string) {
	action();
	discord.picker_search_typed(cur.c, sub(query, 0, 1));
	discord.picker_search_typed(cur.c, query);
	for _: query {
		human(20, 50);
		human(60, 170);
	}
	human(300, 700);
}

last_message :: (channel: discord.Snowflake) -> discord.Snowflake {
	msgs := discord.messages_get(*cur.c.store, channel);
	for < i: 0..len(msgs) - 1 { if msgs[i].author_id == cur.c.store.me && !msgs[i].pending { return msgs[i].id; } }
	return 0;
}

newest_group_dm :: () -> discord.Snowflake {
	best: discord.Snowflake = 0;
	for cid: cur.c.store.private_channels {
		ch := discord.channel_get(*cur.c.store, cid);
		if ch != null && ch.kind == .Group_DM && cid > best { best = cid; }
	}
	return best;
}

CUSTOM_EMOJI :: cast(discord.Snowflake)(1564250154838528071); // fastcord_test (upload_custom_emoji)
// ${GUILD}/${TEXT} of the scenarios: the long-history guild "Dingus Battle"
HGUILD :: cast(discord.Snowflake)(1546820558300258304);
HTEXT :: cast(discord.Snowflake)(1546820603343016006);

// quick_type: the quick switcher input, one keystroke at a time.
quick_type :: (text: string) {
	for i: 1..len(text) {
		discord.quick_switcher_type(cur.c, sub(text, 0, i));
		human(20, 50);
		human(60, 170);
	}
}

last_image :: (channel: discord.Snowflake) -> string {
	msgs := discord.messages_get(*cur.c.store, channel);
	for < i: 0..len(msgs) - 1 {
		for a: msgs[i].attachments { if strings.has_prefix(a.content_type, "image/") { return a.proxy_url; } }
	}
	return "";
}

open_test_channel :: () {
	use("a");
	mark("setup");
	reload();
	click();
	wait_for();
	click();
	discord.select_channel(cur.c, TGUILD, TTEXT, discord.initial_message_limit(VIEW_H), prefetch = true);
	wait_for();
	settle(1500);
}

send_setup_message :: () {
	click();
	typed(TTEXT, "setup message for the next step");
	discord.send_message(cur.c, TTEXT, "setup message for the next step");
	wait_gw("MESSAGE_CREATE");
	settle(1500);
}

friends_home :: () {
	click();
	discord.select_channel(cur.c, 0, 0);
	wait_for();
	click();
	wait_for();
	settle(1000);
}

run :: (name: string) -> bool {
	if name == {
	case "cold_start";
		use("a");
		mark("cold_start");
		reload();
		settle(3000);
	case "send_message";
		open_test_channel();
		mark("send_message");
		click();
		typed(TTEXT, "hello from the official client");
		discord.send_message(cur.c, TTEXT, "hello from the official client"); // same text: same body length
		wait_gw("MESSAGE_CREATE");
		settle(2000);
	case "typing";
		open_test_channel();
		mark("typing");
		click();
		typed(TTEXT, "i am typing something but will not send it");
		pump(4000);
		typed(TTEXT, " and still typing");
		pump(3000);
		mark("typing_clear");
		discord.typing_local_stop(cur.c, TTEXT);
		settle(2000);
	case "add_reaction";
		open_test_channel();
		send_setup_message();
		mark("add_reaction");
		discord.message_menu_opened(cur.c, TGUILD, TTEXT, last_message(TTEXT));
		click();
		human(80, 400); // hover #message-add-reaction
		pause();
		click();
		discord.message_menu_item_clicked(cur.c);
		discord.message_menu_closed(cur.c);
		discord.open_emoji_picker(cur.c, TGUILD);
		discord.expression_picker_opened(cur.c, .Reaction, TGUILD, TTEXT, message_id = last_message(TTEXT));
		wait_for();
		picker_typed("thumbsup");
		click();
		action();
		discord.picker_emoji_selected(cur.c, "thumbsup");
		discord.add_reaction(cur.c, TTEXT, last_message(TTEXT), "👍", 0, false, "Message Reaction Picker");
		wait_gw("MESSAGE_REACTION_ADD");
		settle(2000);
	case "remove_reaction";
		open_test_channel();
		send_setup_message();
		discord.message_menu_opened(cur.c, TGUILD, TTEXT, last_message(TTEXT));
		click();
		click();
		discord.message_menu_item_clicked(cur.c);
		discord.message_menu_closed(cur.c);
		action();
		discord.add_reaction(cur.c, TTEXT, last_message(TTEXT), "👍", 0, false, "Message Context Menu");
		wait_gw("MESSAGE_REACTION_ADD");
		settle(1500);
		mark("remove_reaction");
		action();
		human(80, 400);
		human(80, 220);
		discord.remove_reaction(cur.c, TTEXT, last_message(TTEXT), "👍", 0, false, "Message Inline Button");
		wait_gw("MESSAGE_REACTION_REMOVE");
		settle(2000);
	case "delete_message";
		open_test_channel();
		send_setup_message();
		mark("delete_message");
		discord.message_menu_opened(cur.c, TGUILD, TTEXT, last_message(TTEXT));
		click();
		click();
		discord.message_menu_item_clicked(cur.c);
		discord.message_menu_closed(cur.c);
		wait_for();
		pause();
		human(80, 400);
		human(80, 220);
		action();
		discord.delete_message(cur.c, TTEXT, last_message(TTEXT));
		wait_gw("MESSAGE_DELETE");
		settle(2000);
	case "edit_message";
		open_test_channel();
		send_setup_message();
		mark("edit_message");
		discord.message_menu_opened(cur.c, TGUILD, TTEXT, last_message(TTEXT));
		click();
		click();
		discord.message_menu_item_clicked(cur.c);
		discord.message_menu_closed(cur.c);
		pump(600);
		typed(0, "this message was edited"); // the inline editor sends no typing
		action();
		discord.edit_message(cur.c, TTEXT, last_message(TTEXT), "this message was edited");
		wait_gw("MESSAGE_UPDATE");
		settle(2000);
	case "reply";
		open_test_channel();
		send_setup_message();
		mark("reply");
		target := last_message(TTEXT);
		discord.message_menu_opened(cur.c, TGUILD, TTEXT, last_message(TTEXT));
		click();
		click();
		discord.message_menu_item_clicked(cur.c);
		discord.message_menu_closed(cur.c);
		pump(500);
		typed(TTEXT, "this is a reply");
		discord.send_message(cur.c, TTEXT, "this is a reply", .{reply_to = target, reply_guild_id = TGUILD, mention_replied = false});
		wait_gw("MESSAGE_CREATE");
		settle(2000);
	case "upload_image";
		open_test_channel();
		mark("upload_image");
		png, err := os.read_entire_file("tests/scenarios/assets/test.png", context.allocator);
		if err != null { return false; }
		pump(1500);
		action();
		files := discord.Upload_File.[.{filename = "test.png", mime = "image/png", data = png}];
		discord.send_message(cur.c, TTEXT, "", .{files = files});
		wait_gw("MESSAGE_CREATE", 30000);
		settle(3000);
	case "open_guild_and_channel";
		// The official instance was already running on @me (click home, wait,
		// reload): one start, on the home route.
		use("a");
		mark("setup");
		click(); // home
		pump(1500);
		reload();
		mark("open_guild");
		click();
		discord.select_channel(cur.c, TGUILD, TTEXT, discord.initial_message_limit(VIEW_H), prefetch = true);
		wait_for();
		settle(1500);
		mark("open_channel");
		click();
		wait_for();
		settle(2000);
	case "open_dm";
		use("a");
		mark("setup");
		reload();
		friends_home();
		mark("open_dm");
		human(500, 1100);
		discord.select_channel(cur.c, 0, DM_AB, discord.initial_message_limit(VIEW_H), prefetch = true);
		settle(2500);
	case "send_dm";
		use("b");
		mark("setup_b");
		reload();
		friends_home();
		use("a");
		mark("setup");
		reload();
		friends_home();
		human(500, 1100);
		discord.select_channel(cur.c, 0, DM_AB, discord.initial_message_limit(VIEW_H));
		settle(1500);
		mark("send_dm");
		typed(DM_AB, "hey bobbles, this is a dm");
		discord.send_message(cur.c, DM_AB, "hey bobbles, this is a dm");
		wait_gw("MESSAGE_CREATE");
		use("b");
		wait_gw("MESSAGE_CREATE", 20000);
		settle(2500);
	case "open_profile_popout";
		open_test_channel();
		send_setup_message();
		mark("open_profile_popout");
		human(80, 400);
		discord.open_profile_popout(cur.c, A_ID, TGUILD, TTEXT, last_message(TTEXT));
		human(500, 1100);
		wait_for();
		settle(2000);
		mark("close_profile_popout");
		discord.analytics_keyboard_shortcut(cur.c, "MARK_CHANNEL_READ", "esc");
		settle(1000);
	case "open_full_profile";
		open_test_channel();
		send_setup_message();
		human(500, 1100);
		discord.open_profile_popout(cur.c, A_ID, TGUILD, TTEXT, last_message(TTEXT));
		settle(1500);
		mark("open_full_profile");
		human(500, 1100);
		discord.open_full_profile(cur.c, A_ID, TGUILD);
		settle(2500);
		mark("close_full_profile");
		discord.analytics_keyboard_shortcut(cur.c, "MARK_CHANNEL_READ", "esc");
		settle(1000);
	case "join_voice_channel";
		open_test_channel();
		mark("join_voice");
		human(500, 1100);
		action();
		discord.voice_join(cur.c, TGUILD, TVOICE);
		wait_gw("VOICE_SERVER_UPDATE", 20000);
		pump(8000);
		mark("leave_voice");
		human(500, 1100);
		discord.voice_leave(cur.c);
		settle(3000);
	case "switch_theme";
		open_test_channel();
		mark("open_settings");
		click();
		discord.open_user_settings(cur.c);
		wait_for();
		click();
		wait_for();
		settle(1500);
		mark("theme_light");
		human(80, 400);
		discord.set_theme(cur.c, .Light);
		human(500, 1100);
		settle(2500);
		mark("theme_dark");
		human(80, 400);
		discord.set_theme(cur.c, .Darker); // the UI's "Dark" is proto DARKER (3)
		human(500, 1100);
		settle(2500);
		mark("close_settings");
		settle(1500);
	case "friend_request_send";
		use("b");
		mark("setup_b");
		reload();
		friends_home();
		use("a");
		mark("setup");
		reload();
		friends_home();
		mark("friend_request_send");
		human(500, 1100);
		typed(0, B_NAME);
		pause();
		action();
		discord.send_friend_request(cur.c, B_NAME);
		wait_gw("RELATIONSHIP_ADD");
		use("b");
		wait_gw("RELATIONSHIP_ADD", 20000);
		settle(2000);
	case "friend_request_accept";
		use("a");
		mark("setup");
		reload();
		friends_home();
		use("b");
		mark("setup_b");
		reload();
		friends_home();
		mark("friend_request_accept");
		human(500, 1100);
		pause();
		action();
		discord.accept_friend_request(cur.c, A_ID);
		wait_gw("RELATIONSHIP_ADD", 20000);
		use("a");
		wait_gw("RELATIONSHIP_ADD", 20000);
		settle(2500);
	case "friend_remove";
		use("b");
		mark("setup_b");
		reload();
		use("a");
		mark("setup");
		reload();
		friends_home();
		settle(1000);
		mark("friend_remove");
		human(500, 1100);
		pause();
		action();
		discord.remove_relationship(cur.c, B_ID, "Friends");
		wait_gw("RELATIONSHIP_REMOVE");
		use("b");
		wait_gw("RELATIONSHIP_REMOVE", 20000);
		settle(2500);
	case "create_guild";
		use("a");
		reload();
		mark("create_guild_open");
		click();
		wait_for();
		pause();
		click(); // Create My Own
		pause();
		click(); // For me and my friends
		customize_shown := discord.now_ms(); // the "Customize your server" step
		wait_for();
		mark("create_guild_name");
		click();
		human(80, 200); // key a meta (does not select in the official run)
		typed(0, "fastcord test");
		pause();
		mark("create_guild_submit");
		human(80, 400);
		human(80, 220);
		action();
		discord.create_guild(cur.c, "Dingus Battle's serverfastcord test", step_shown_ms = customize_shown);
		wait_gw("GUILD_CREATE", 20000);
		settle(2500);
	case "start_group_dm";
		use("b");
		mark("setup_b");
		reload();
		use("a");
		mark("setup");
		reload();
		friends_home();
		mark("start_group_dm");
		click();
		discord.group_dm_picker_opened(cur.c, .{"New Group DM", "Friends List"}, 0, 2);
		wait_for();
		pause();
		click();
		action();
		discord.create_group_dm(cur.c);
		wait_gw("CHANNEL_CREATE");
		gdm := newest_group_dm();
		discord.select_channel(cur.c, 0, gdm, discord.initial_message_limit(VIEW_H));
		wait_for();
		settle(2000);
		mark("invite_to_group_dm");
		click();
		discord.create_group_dm_invite(cur.c, gdm);
		wait_for();
		click(); // bobbles checkbox
		pause();
		click(); // Add (the official run issues no PUT here: B was not a friend)
		wait_gw("CHANNEL_RECIPIENT_ADD", 3000);
		use("b");
		wait_gw("CHANNEL_CREATE", 5000);
		settle(2500);
	case "add_custom_reaction";
		open_test_channel();
		send_setup_message();
		mark("add_custom_reaction");
		discord.message_menu_opened(cur.c, TGUILD, TTEXT, last_message(TTEXT));
		click();
		human(80, 400); // hover #message-add-reaction
		pause();
		click();
		discord.message_menu_item_clicked(cur.c);
		discord.message_menu_closed(cur.c);
		discord.open_emoji_picker(cur.c, TGUILD);
		discord.expression_picker_opened(cur.c, .Reaction, TGUILD, TTEXT, message_id = last_message(TTEXT));
		wait_for();
		picker_typed("fastcord");
		click();
		action();
		discord.picker_emoji_selected(cur.c, "fastcord_test", CUSTOM_EMOJI, TGUILD);
		discord.add_reaction(cur.c, TTEXT, last_message(TTEXT), "fastcord_test", CUSTOM_EMOJI, false, "Message Reaction Picker");
		wait_gw("MESSAGE_REACTION_ADD");
		settle(2000);
	case "emoji_picker_reaction";
		open_test_channel();
		send_setup_message();
		discord.message_menu_opened(cur.c, TGUILD, TTEXT, last_message(TTEXT));
		click();
		click(); // #message-quickreact-0
		discord.message_menu_item_clicked(cur.c);
		discord.message_menu_closed(cur.c);
		action();
		discord.add_reaction(cur.c, TTEXT, last_message(TTEXT), "👍", 0, false, "Message Context Menu");
		wait_gw("MESSAGE_REACTION_ADD");
		settle(1500);
		mark("emoji_picker_reaction");
		click(); // the reaction bar's add-reaction button
		discord.open_emoji_picker(cur.c, TGUILD);
		discord.expression_picker_opened(cur.c, .Reaction, TGUILD, TTEXT, message_id = last_message(TTEXT));
		wait_for();
		picker_typed("fire");
		click();
		action();
		discord.picker_emoji_selected(cur.c, "fire");
		discord.add_reaction(cur.c, TTEXT, last_message(TTEXT), "🔥", 0, false, "Message Inline Button");
		wait_gw("MESSAGE_REACTION_ADD");
		settle(2000);
	case "gif_send";
		open_test_channel();
		mark("open_gif_picker");
		click();
		discord.gifs_trending(cur.c);
		discord.expression_picker_opened(cur.c, .Gif, TGUILD, TTEXT, width = 498);
		wait_for();
		settle(1500);
		mark("search_gif");
		click();
		typed(0, "cat");
		pump(250); // the picker's search debounce
		discord.gifs_search(cur.c, "cat");
		pump(2250);
		settle(1500);
		mark("send_gif");
		click();
		action();
		// the first result of the official run; the picker sends its page URL
		discord.gif_select(cur.c, "goatplaybanjo-chat-4", "cat");
		discord.send_message(cur.c, TTEXT, "https://klipy.com/gifs/goatplaybanjo-chat-4");
		wait_gw("MESSAGE_CREATE", 20000);
		settle(2500);
	case "open_image_attachment";
		open_test_channel();
		mark("open_image");
		click();
		img := last_image(TTEXT);
		if img != "" { discord.fetch_media(cur.c, .{url = discord.media_viewer_url(img), kind = .Image, visible = true}); }
		wait_for();
		settle(2500);
		mark("close_image");
		human(80, 200); // Escape
		settle(1500);
	case "scroll_history";
		use("a");
		mark("setup");
		reload();
		click();
		wait_for();
		click();
		discord.select_channel(cur.c, HGUILD, HTEXT, discord.initial_message_limit(VIEW_H), prefetch = true);
		wait_for();
		settle(2000);
		// the older pages are already loaded by the channel open (fixture: no requests)
		for n: 1..3 {
			mark(fmt.tprintf("scroll_up_%d", n));
			settle(2500);
		}
	case "quick_switcher_nav";
		open_test_channel();
		mark("switch_to_dm");
		human(80, 200); // Cmd+K
		pump(1000);
		quick_type("bobbles");
		pump(1200);
		discord.quick_switcher_close(cur.c);
		discord.select_channel(cur.c, 0, DM_AB, discord.initial_message_limit(VIEW_H));
		wait_for();
		settle(2500);
		mark("switch_to_channel");
		human(80, 200);
		pump(1000);
		quick_type("general");
		pump(1200);
		discord.quick_switcher_close(cur.c);
		discord.select_channel(cur.c, TGUILD, TTEXT, discord.initial_message_limit(VIEW_H));
		wait_for();
		settle(2500);
	case "status_change";
		use("a");
		mark("setup");
		reload();
		friends_home();
		mark("open_status_menu");
		click();
		discord.open_account_popout(cur.c);
		pump(1200);
		click(); // "Your Status" submenu
		pump(1200);
		mark("set_idle");
		click();
		action();
		discord.set_status(cur.c, .Idle);
		wait_gw("USER_SETTINGS_PROTO_UPDATE", 10000);
		settle(2500);
		mark("set_online");
		click();
		pump(1200);
		click();
		action();
		discord.set_status(cur.c, .Online);
		wait_gw("USER_SETTINGS_PROTO_UPDATE", 10000);
		settle(2500);
		human(80, 200); // Escape
		pump(500);
	case "custom_status";
		use("a");
		mark("setup");
		reload();
		friends_home();
		mark("open_custom_status");
		click();
		discord.open_account_popout(cur.c);
		pump(1200);
		click(); // Add custom status
		pump(1500);
		mark("set_custom_status");
		typed(0, "testing fastcord");
		human(80, 200); // Enter
		action();
		discord.set_custom_status(cur.c, .{text = "testing fastcord", expires_at_ms = discord.now_ms() + 24 * 3600 * 1000, clear_after = .Today});
		wait_gw("USER_SETTINGS_PROTO_UPDATE", 10000);
		settle(2500);
		mark("clear_custom_status");
		click();
		discord.open_account_popout(cur.c);
		pump(1500);
		human(80, 400); // hover
		pump(800);
		click(); // Clear custom status
		action();
		discord.set_custom_status(cur.c, .{});
		wait_gw("USER_SETTINGS_PROTO_UPDATE", 10000);
		settle(2500);
		human(80, 200);
		settle(1000);
	case "close_dm";
		use("a");
		mark("setup");
		reload();
		friends_home();
		mark("close_dm");
		discord.private_channel_menu_opened(cur.c); // right click: impression + the user command index
		click();
		wait_for();
		click(); // Close DM
		action();
		discord.close_private_channel(cur.c, DM_AB);
		wait_gw("CHANNEL_DELETE", 10000);
		settle(2500);
		mark("reopen_dm");
		human(80, 200);
		pump(1000);
		quick_type("bobbles");
		pump(1200);
		human(80, 200); // Enter
		discord.quick_switcher_close(cur.c);
		action();
		discord.open_dm(cur.c, B_ID, "Quickswitcher");
		wait_gw("CHANNEL_CREATE", 10000);
		discord.select_channel(cur.c, 0, DM_AB, discord.initial_message_limit(VIEW_H));
		wait_for();
		settle(2500);
	case "mark_as_read";
		use("b");
		mark("setup_b");
		reload();
		click();
		wait_for();
		click();
		discord.select_channel(cur.c, TGUILD, TTEXT, discord.initial_message_limit(VIEW_H), prefetch = true);
		wait_for();
		use("a");
		mark("setup");
		reload();
		friends_home();
		use("b");
		mark("b_sends");
		click();
		typed(TTEXT, "unread message for the ack test");
		human(80, 200); // Enter
		action();
		discord.send_message(cur.c, TTEXT, "unread message for the ack test");
		wait_gw("MESSAGE_CREATE");
		use("a");
		wait_gw("MESSAGE_CREATE", 20000);
		settle(2000);
		mark("open_unread_channel");
		click();
		discord.select_channel(cur.c, TGUILD, TTEXT, discord.initial_message_limit(VIEW_H), prefetch = true);
		wait_for();
		click();
		wait_for();
		settle(4000);
	case "voice_with_b";
		use("b");
		mark("setup_b");
		reload();
		click();
		discord.select_channel(cur.c, TGUILD, TTEXT, discord.initial_message_limit(VIEW_H), prefetch = true);
		wait_for();
		settle(1000);
		open_test_channel();
		use("b");
		mark("b_join_voice");
		click();
		action();
		discord.voice_join(cur.c, TGUILD, TVOICE);
		wait_gw("VOICE_SERVER_UPDATE", 20000);
		pump(3000);
		use("a");
		mark("a_join_voice");
		click();
		action();
		discord.voice_join(cur.c, TGUILD, TVOICE);
		wait_gw("VOICE_SERVER_UPDATE", 20000);
		pump(8000);
		mark("a_leave_voice");
		click();
		discord.voice_leave(cur.c);
		settle(2000);
		use("b");
		mark("b_leave_voice");
		click();
		discord.voice_leave(cur.c);
		settle(2500);
	case "_cleanup";
		// not a fixture: removes guilds/group DMs the create_* scenarios left behind
		use("a");
		reload();
		for gid: cur.c.store.guild_order {
			g := discord.guild_get(*cur.c.store, gid);
			if gid != TGUILD && g != null && g.owner_id == A_ID && g.name == "Dingus Battle's serverfastcord test" {
				discord.delete_guild(cur.c, gid);
				pump(1500);
			}
		}
		for cid: cur.c.store.private_channels {
			ch := discord.channel_get(*cur.c.store, cid);
			if ch != null && ch.kind == .Group_DM && ch.owner_id == A_ID && len(ch.recipient_ids) == 0 {
				discord.close_private_channel(cur.c, cid);
				pump(1500);
			}
		}
		settle(2000);
	case "_reset_friendship";
		// not a fixture: puts A and B back to "not friends" before friend_request_send
		use("a");
		reload();
		discord.remove_relationship(cur.c, B_ID, "Friends");
		settle(2000);
	case;
		return false;
	}
	return true;
}

// session: one launch of A (B launches the first time a scenario uses it), then
// every scenario at human pace. Each scenario gets its own recording; requests
// already in flight when it switches stay in the previous one.
session :: (dir: string, names: []string) {
	session_mode = true;
	accts[0] = .{name = "a", token = token_a(), state = ".secrets/parity-state-a"};
	accts[1] = .{name = "b", token = token_b(), state = ".secrets/parity-state-b"};
	if accts[0].token == "" {
		fmt.eprintln("no token for A");
		os.exit(1);
	}
	for name, i: names {
		scenario = name;
		out := fmt.tprintf("%s/ours_%s.jsonl", dir, name);
		next, ok := discord.recorder_open(out);
		if !ok {
			fmt.eprintln("cannot open", out);
			os.exit(1);
		}
		for * a: accts { if a.c != null { discord.recorder_attach(next, a.c, a.name); } }
		prev := rec;
		rec = next;
		if prev != null { discord.recorder_retire(prev); }
		cur = *accts[0];
		if !run(name) { fmt.eprintln("unknown or failed scenario:", name); }
		settle(2000, 15000);
		fmt.println(name, "->", out);
		if i + 1 < len(names) { human(3000, 7000); } // reading before the next thing
	}
	for * a: accts { if a.c != null { stop(a); } }
	discord.recorder_retire(rec);
}

SESSION_SCENARIOS :: string.["cold_start", "send_message", "typing", "add_reaction", "remove_reaction", "delete_message",
	"edit_message", "reply", "upload_image", "open_profile_popout", "open_full_profile",
	"emoji_picker_reaction", "add_custom_reaction", "gif_send", "open_image_attachment",
	"scroll_history", "quick_switcher_nav", "switch_theme", "join_voice_channel", "status_change",
	"custom_status", "open_guild_and_channel", "open_dm", "close_dm", "start_group_dm", "create_guild",
	"_cleanup", "mark_as_read", "voice_with_b", "_reset_friendship", "friend_request_send",
	"friend_request_accept", "send_dm", "friend_remove"];
CORE_IGNORES :: string.["-ignore:/science", "-ignore:/assets/", "-ignore:collectibles-shop", "-ignore:latency.discord.media", "-ignore:/cdn-cgi/"];

// session_report (was session.sh): one human-paced session over every scenario,
// recorded into .secrets/raw, then scrubbed into .secrets/ours and diffed against
// its fixture's action windows. Run from the repo root after `jai build.jai - parity`.
session_report :: (args: []string) {
	names := ifx len(args) then args else SESSION_SCENARIOS;
	jai := ifx OS == .MACOS then "jai-macos" else ifx OS == .WINDOWS then "jai.exe" else "jai-linux";
	for t: string.["scrub", "trafficdiff"] { must(run_cmd(string.[jai, "build.jai", "-", "tool", t])); }
	os.make_directory_all(".secrets/raw");
	os.make_directory_all(".secrets/ours");
	for s: names for x: string.["a", "b"] {
		nl := fmt.tprintf(".secrets/raw/ours_%s.jsonl.netlog-%s", s, x);
		if os.exists(nl) { os.remove_(nl); }
	}
	session(".secrets/raw", names);
	fmt.printf("%-24s %5s %5s\n", "scenario", "all", "core");
	for s: names {
		raw := fmt.tprintf(".secrets/raw/ours_%s.jsonl", s);
		ours := fmt.tprintf(".secrets/ours/%s.jsonl", s);
		fix := fmt.tprintf("traffic/%s.jsonl", s);
		scrub: [..]string;
		array_add(*scrub, "build/scrub", raw, ours);
		for x: string.["a", "b"] {
			nl := fmt.tprintf("%s.netlog-%s", raw, x);
			if os.exists(nl) { array_add(*scrub, fmt.tprintf("-netlog-%s:%s", x, nl)); }
		}
		must(run_cmd(scrub));
		if !os.exists(fix) { continue; }
		all: [..]string;
		array_add(*all, "build/trafficdiff");
		if s != "cold_start" { array_add(*all, "-actions"); }
		core: [..]string;
		array_add(*core, ..all);
		array_add(*core, ..CORE_IGNORES);
		array_add(*all, fix, ours);
		array_add(*core, fix, ours);
		_, all_out := run_cmd(all);
		os.write_entire_file(fmt.tprintf(".secrets/ours/%s.diff", s), all_out);
		_, core_out := run_cmd(core);
		fmt.printf("%-24s %5s %5s\n", s, diff_count(all_out), diff_count(core_out));
	}
}

