// parity: performs tests/scenarios/<name>.scn with fastcord's discord library
// against the live server as the test accounts, recording our traffic in the
// raw capture format (.secrets/raw/ours_<name>.jsonl). run.sh then scrubs it
// with tools/scrub and diffs it against traffic/<name>.jsonl with tools/trafficdiff.
//
//   parity <scenario> [out.jsonl]      (run from the repo root)
//
// Tokens are read at runtime (A: IDENTIFY in .secrets/raw/gw_a.jsonl,
// B: Authorization in .secrets/raw/coldstart_b.jsonl) and never printed.
// Each scenario mirrors the .scn step by step: same marks, the library call the
// UI action triggers, the same waits; human pacing like tools/capture.
package parity

import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:strings"
import "core:sync"
import "core:time"
import "fc:discord"
import "fc:etf"

A_ID :: discord.Snowflake(1546819257420087346)
B_ID :: discord.Snowflake(1564202918369042442)
B_NAME :: "bobbles_2345"
TGUILD :: discord.Snowflake(1564227669971832975)
TTEXT :: discord.Snowflake(1564227670806364343)
TVOICE :: discord.Snowflake(1564227670806364345)
DM_AB :: discord.Snowflake(1564228964451356713)
VIEW_W :: 1280
VIEW_H :: 720

Acct :: struct {
	name:   string,
	token:  string,
	state:  string,
	c:      ^discord.Client,
	events: [dynamic]string, // received dispatch names (cursor-based waits)
	cursor: int,
}

rec: ^discord.Recorder
scenario: string
reloads: [2]int

// start_route: the route the official instance reopened on at the n-th reload
// of this account, read from traffic/<scenario>.jsonl (first messages?limit=
// page and lurker PUT after each ws_open).
start_route :: proc(acct: string, n: int) -> (guild, channel: discord.Snowflake) {
	data, err := os.read_entire_file(fmt.tprintf("traffic/%s.jsonl", scenario), context.temp_allocator)
	if err != nil do return 0, 0
	text := string(data)
	opens := -1
	for line in strings.split_lines_iterator(&text) {
		v, jerr := etf.from_json(line, context.temp_allocator)
		if jerr != .None do continue
		m := discord.vmap(v)
		a := discord.fstr(m, "acct")
		if a == "" do a = "a"
		if a != acct do continue
		k := discord.fstr(m, "k")
		if k == "ws_open" {
			opens += 1
			if opens > n do break
			continue
		}
		if opens != n || k != "req" do continue
		url := discord.fstr(m, "url")
		if i := strings.index(url, "/guilds/"); i >= 0 && strings.contains(url, "lurker=true") {
			rest := url[i + 8:]
			guild = discord.parse_snowflake(rest[:strings.index_byte(rest, '/')])
		}
		if i := strings.index(url, "/channels/"); i >= 0 && strings.contains(url, "/messages?limit=") && channel == 0 {
			rest := url[i + 10:]
			channel = discord.parse_snowflake(rest[:strings.index_byte(rest, '/')])
		}
	}
	return
}
accts: [2]Acct
cur: ^Acct

main :: proc() {
	args := os.args
	if len(args) < 2 {
		fmt.eprintln("usage: parity <scenario> [out.jsonl]")
		os.exit(2)
	}
	name := args[1]
	scenario = name
	out := args[2] if len(args) > 2 else fmt.tprintf(".secrets/raw/ours_%s.jsonl", name)
	accts[0] = {name = "a", token = token_a(), state = ".secrets/parity-state-a"}
	accts[1] = {name = "b", token = token_b(), state = ".secrets/parity-state-b"}
	if accts[0].token == "" {
		fmt.eprintln("no token for A")
		os.exit(1)
	}
	ok: bool
	rec, ok = discord.recorder_open(out)
	if !ok {
		fmt.eprintln("cannot open", out)
		os.exit(1)
	}
	cur = &accts[0]
	ran := run(name)
	if ran do settle(2000, 15000)
	for &a in accts do if a.c != nil do stop(&a)
	discord.recorder_close(rec)
	if !ran {
		fmt.eprintln("unknown or failed scenario:", name)
		os.exit(1)
	}
	fmt.println(name, "->", out)
}

// ---- tokens (never printed) ----

token_a :: proc() -> string {
	data, err := os.read_entire_file(".secrets/raw/gw_a.jsonl", context.allocator)
	if err != nil do return ""
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		if !strings.contains(line, `"op":2`) && !strings.contains(line, `"op": 2`) do continue
		v, jerr := etf.from_json(line)
		if jerr != .None do continue
		e := discord.fmap(discord.vmap(v), "etf")
		if discord.fint(e, "op") == 2 do return discord.fstr(discord.fmap(e, "d"), "token")
	}
	return ""
}

token_b :: proc() -> string {
	f, err := os.open(".secrets/raw/coldstart_b.jsonl")
	if err != nil do return ""
	defer os.close(f)
	buf: [1 << 16]byte
	carry := make([dynamic]byte)
	for {
		n, rerr := os.read(f, buf[:])
		if n <= 0 || rerr != nil do break
		append(&carry, ..buf[:n])
		s := string(carry[:])
		if i := strings.index(s, `"Authorization": "`); i >= 0 {
			rest := s[i + len(`"Authorization": "`):]
			if j := strings.index_byte(rest, '"'); j >= 0 do return strings.clone(rest[:j])
		}
		if i := strings.index(s, `"Authorization":"`); i >= 0 {
			rest := s[i + len(`"Authorization":"`):]
			if j := strings.index_byte(rest, '"'); j >= 0 do return strings.clone(rest[:j])
		}
		if len(carry) > 1 << 20 do remove_range(&carry, 0, len(carry) - 4096)
	}
	return ""
}

// ---- driving ----

use :: proc(n: string) {cur = &accts[0] if n == "a" else &accts[1]}

mark :: proc(n: string) {discord.recorder_mark(rec, cur.name, n)}

// reload: the app restarts on the same profile (cookies, alt-svc, heartbeat
// session persisted) and reopens on the route the official instance was on.
reload :: proc() {
	a := cur
	idx := 0 if a.name == "a" else 1
	guild, channel := start_route(a.name, reloads[idx])
	reloads[idx] += 1
	if a.c != nil do stop(a)
	clear(&a.events)
	a.cursor = 0
	a.c = discord.client_create(discord.Config{token = a.token, state_dir = a.state, initial_guild_id = guild, initial_channel_id = channel})
	discord.recorder_attach(rec, a.c, a.name)
	// recorder_attach owns observer_data; route gateway dispatch names to us via the recv hook data
	a.c.user_data = a
	a.c.on_dispatch = proc(user: rawptr, name: string) {
		acct := cast(^Acct)user
		// The capture instances lose window focus once loaded: AppStateStore
		// reports "unfocused" from READY on (QoS stays foregrounded).
		if name == "READY" do discord.identity_set_app_state(&acct.c.id, .Unfocused)
		sync.mutex_lock(&names_mu)
		append(&acct.events, strings.clone(name))
		sync.mutex_unlock(&names_mu)
	}
	discord.client_set_viewport(a.c, VIEW_W, VIEW_H)
	discord.client_set_accessibility(a.c, discord.A11Y_PREFERS_COLOR_SCHEME_LIGHT)
	discord.client_start(a.c)
	wait_gw("READY", 45000)
	settle(2500, 30000)
}

names_mu: sync.Mutex

stop :: proc(a: ^Acct) {
	discord.client_destroy(a.c)
	a.c = nil
}

pump :: proc(ms: int) {
	deadline := time.tick_now()
	for time.tick_since(deadline) < time.Duration(ms) * time.Millisecond {
		for &a in accts do if a.c != nil do discord.client_poll(a.c)
		time.sleep(16 * time.Millisecond)
	}
}

human :: proc(lo, hi: int) {pump(lo + int(rand.uint32() % u32(hi - lo + 1)))}

// click: tools/capture's mouse move (4-25 steps of 8-22 ms, then 80-220 ms),
// the click, then 500-1100 ms.
click :: proc() {
	human(80, 400)
	human(80, 220)
	human(500, 1100)
}

// wait_for: DOM polling every 250 ms (half a period on average).
wait_for :: proc() {pump(125 + int(rand.uint32() % 250))}
pause :: proc() {human(700, 1600)}

// settle: like tools/capture — wait until no network event for quiet_ms (max max_ms).
settle :: proc(quiet_ms: int, max_ms := 20000) {
	start := time.tick_now()
	for time.tick_since(start) < time.Duration(max_ms) * time.Millisecond {
		if discord.now_ms() - discord.recorder_last_net(rec) >= i64(quiet_ms) do return
		pump(200)
	}
}

// wait_gw: until a dispatch arrives on the current account since the last action.
wait_gw :: proc(ev: string, timeout_ms := 15000) -> bool {
	deadline := time.tick_now()
	for time.tick_since(deadline) < time.Duration(timeout_ms) * time.Millisecond {
		for &a in accts do if a.c != nil do discord.client_poll(a.c)
		sync.mutex_lock(&names_mu)
		for i := cur.cursor; i < len(cur.events); i += 1 {
			if cur.events[i] == ev {
				cur.cursor = i + 1
				sync.mutex_unlock(&names_mu)
				return true
			}
		}
		sync.mutex_unlock(&names_mu)
		time.sleep(16 * time.Millisecond)
	}
	fmt.eprintln("timeout waiting for", ev)
	return false
}

action :: proc() {
	sync.mutex_lock(&names_mu)
	cur.cursor = len(cur.events)
	sync.mutex_unlock(&names_mu)
}

typed :: proc(channel: discord.Snowflake, text: string) {
	action()
	for _ in text {
		if channel != 0 do discord.typing_keystroke(cur.c, channel)
		human(20, 50)
		human(60, 170)
	}
	human(300, 700)
}

last_message :: proc(channel: discord.Snowflake) -> discord.Snowflake {
	msgs := discord.messages_get(&cur.c.store, channel)
	for i := len(msgs) - 1; i >= 0; i -= 1 do if msgs[i].author_id == cur.c.store.me && !msgs[i].pending do return msgs[i].id
	return 0
}

open_test_channel :: proc() {
	use("a")
	mark("setup")
	reload()
	click()
	wait_for()
	click()
	discord.select_channel(cur.c, TGUILD, TTEXT, discord.initial_message_limit(VIEW_H))
	wait_for()
	settle(1500)
}

send_setup_message :: proc() {
	click()
	typed(TTEXT, "setup message for the next step")
	discord.send_message(cur.c, TTEXT, "setup message for the next step")
	wait_gw("MESSAGE_CREATE")
	settle(1500)
}

friends_home :: proc() {
	click()
	discord.select_channel(cur.c, 0, 0)
	wait_for()
	click()
	wait_for()
	settle(1000)
}

run :: proc(name: string) -> bool {
	switch name {
	case "cold_start":
		use("a")
		mark("cold_start")
		reload()
		settle(3000)
	case "send_message":
		open_test_channel()
		mark("send_message")
		click()
		typed(TTEXT, "hello from the official client")
		discord.send_message(cur.c, TTEXT, "hello from fastcord")
		wait_gw("MESSAGE_CREATE")
		settle(2000)
	case "typing":
		open_test_channel()
		mark("typing")
		click()
		typed(TTEXT, "i am typing something but will not send it")
		pump(4000)
		typed(TTEXT, " and still typing")
		pump(3000)
		mark("typing_clear")
		discord.typing_local_stop(cur.c, TTEXT)
		settle(2000)
	case "add_reaction":
		open_test_channel()
		send_setup_message()
		mark("add_reaction")
		discord.open_message_context_menu(cur.c, TGUILD)
		click()
		human(80, 400) // hover #message-add-reaction
		pause()
		click()
		discord.open_emoji_picker(cur.c, TGUILD)
		wait_for()
		typed(0, "thumbsup")
		pump(800)
		click()
		action()
		discord.add_reaction(cur.c, TTEXT, last_message(TTEXT), "👍", 0, false, "Message Reaction Picker")
		wait_gw("MESSAGE_REACTION_ADD")
		settle(2000)
	case "remove_reaction":
		open_test_channel()
		send_setup_message()
		discord.open_message_context_menu(cur.c, TGUILD)
		click()
		click()
		action()
		discord.add_reaction(cur.c, TTEXT, last_message(TTEXT), "👍", 0, false, "Message Context Menu")
		wait_gw("MESSAGE_REACTION_ADD")
		settle(1500)
		mark("remove_reaction")
		action()
		human(80, 400)
		human(80, 220)
		discord.remove_reaction(cur.c, TTEXT, last_message(TTEXT), "👍", 0, false, "Message Inline Button")
		wait_gw("MESSAGE_REACTION_REMOVE")
		settle(2000)
	case "delete_message":
		open_test_channel()
		send_setup_message()
		mark("delete_message")
		discord.open_message_context_menu(cur.c, TGUILD)
		click()
		click()
		wait_for()
		pause()
		human(80, 400)
		human(80, 220)
		action()
		discord.delete_message(cur.c, TTEXT, last_message(TTEXT))
		wait_gw("MESSAGE_DELETE")
		settle(2000)
	case "edit_message":
		open_test_channel()
		send_setup_message()
		mark("edit_message")
		discord.open_message_context_menu(cur.c, TGUILD)
		click()
		click()
		pump(600)
		typed(TTEXT, "this message was edited")
		action()
		discord.edit_message(cur.c, TTEXT, last_message(TTEXT), "this message was edited")
		wait_gw("MESSAGE_UPDATE")
		settle(2000)
	case "reply":
		open_test_channel()
		send_setup_message()
		mark("reply")
		target := last_message(TTEXT)
		discord.open_message_context_menu(cur.c, TGUILD)
		click()
		click()
		pump(500)
		typed(TTEXT, "this is a reply")
		discord.send_message(cur.c, TTEXT, "this is a reply", {reply_to = target, reply_guild_id = TGUILD, mention_replied = false})
		wait_gw("MESSAGE_CREATE")
		settle(2000)
	case "upload_image":
		open_test_channel()
		mark("upload_image")
		png, err := os.read_entire_file("tests/scenarios/assets/test.png", context.allocator)
		if err != nil do return false
		pump(1500)
		action()
		files := []discord.Upload_File{{filename = "test.png", mime = "image/png", data = png}}
		discord.send_message(cur.c, TTEXT, "", {files = files})
		wait_gw("MESSAGE_CREATE", 30000)
		settle(3000)
	case "open_guild_and_channel":
		// The official instance was already running on @me (click home, wait,
		// reload): one start, on the home route.
		use("a")
		mark("setup")
		reload()
		mark("open_guild")
		click()
		discord.select_channel(cur.c, TGUILD, TTEXT, discord.initial_message_limit(VIEW_H))
		wait_for()
		settle(1500)
		mark("open_channel")
		click()
		wait_for()
		settle(2000)
	case "open_dm":
		use("a")
		mark("setup")
		reload()
		friends_home()
		mark("open_dm")
		human(500, 1100)
		discord.select_channel(cur.c, 0, DM_AB, discord.initial_message_limit(VIEW_H))
		settle(2500)
	case "send_dm":
		use("b")
		mark("setup_b")
		reload()
		friends_home()
		use("a")
		mark("setup")
		reload()
		friends_home()
		human(500, 1100)
		discord.select_channel(cur.c, 0, DM_AB, discord.initial_message_limit(VIEW_H))
		settle(1500)
		mark("send_dm")
		typed(DM_AB, "hey bobbles, this is a dm")
		discord.send_message(cur.c, DM_AB, "hey bobbles, this is a dm")
		wait_gw("MESSAGE_CREATE")
		use("b")
		wait_gw("MESSAGE_CREATE", 20000)
		settle(2500)
	case "open_profile_popout":
		open_test_channel()
		send_setup_message()
		mark("open_profile_popout")
		human(80, 400)
		discord.open_profile_popout(cur.c, A_ID, TGUILD)
		human(500, 1100)
		wait_for()
		settle(2000)
		mark("close_profile_popout")
		settle(1000)
	case "open_full_profile":
		open_test_channel()
		send_setup_message()
		human(500, 1100)
		discord.open_profile_popout(cur.c, A_ID, TGUILD)
		settle(1500)
		mark("open_full_profile")
		human(500, 1100)
		discord.open_full_profile(cur.c, A_ID, TGUILD)
		settle(2500)
		mark("close_full_profile")
		settle(1000)
	case "join_voice_channel":
		open_test_channel()
		mark("join_voice")
		human(500, 1100)
		action()
		discord.voice_join(cur.c, TGUILD, TVOICE)
		wait_gw("VOICE_SERVER_UPDATE", 20000)
		pump(8000)
		mark("leave_voice")
		human(500, 1100)
		discord.voice_leave(cur.c)
		settle(3000)
	case "switch_theme":
		open_test_channel()
		mark("open_settings")
		click()
		discord.open_user_settings(cur.c)
		wait_for()
		click()
		wait_for()
		settle(1500)
		mark("theme_light")
		human(80, 400)
		discord.set_theme(cur.c, .Light)
		human(500, 1100)
		settle(2500)
		mark("theme_dark")
		human(80, 400)
		discord.set_theme(cur.c, .Darker) // the UI's "Dark" is proto DARKER (3)
		human(500, 1100)
		settle(2500)
		mark("close_settings")
		settle(1500)
	case "friend_request_send":
		use("b")
		mark("setup_b")
		reload()
		friends_home()
		use("a")
		mark("setup")
		reload()
		friends_home()
		mark("friend_request_send")
		human(500, 1100)
		typed(0, B_NAME)
		pause()
		action()
		discord.send_friend_request(cur.c, B_NAME)
		wait_gw("RELATIONSHIP_ADD")
		use("b")
		wait_gw("RELATIONSHIP_ADD", 20000)
		settle(2000)
	case "friend_request_accept":
		use("a")
		mark("setup")
		reload()
		friends_home()
		use("b")
		mark("setup_b")
		reload()
		friends_home()
		mark("friend_request_accept")
		human(500, 1100)
		pause()
		action()
		discord.accept_friend_request(cur.c, A_ID)
		wait_gw("RELATIONSHIP_ADD", 20000)
		use("a")
		wait_gw("RELATIONSHIP_ADD", 20000)
		settle(2500)
	case "friend_remove":
		use("b")
		mark("setup_b")
		reload()
		use("a")
		mark("setup")
		reload()
		friends_home()
		settle(1000)
		mark("friend_remove")
		human(500, 1100)
		pause()
		action()
		discord.remove_relationship(cur.c, B_ID, "Friends")
		wait_gw("RELATIONSHIP_REMOVE")
		use("b")
		wait_gw("RELATIONSHIP_REMOVE", 20000)
		settle(2500)
	case:
		return false
	}
	return true
}
