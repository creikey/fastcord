package discord

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import "fc:etf"
import "fc:http"

// Live test against account A. Run with FASTCORD_LIVE=1. The token is read at
// test time from the captured IDENTIFY in .secrets/raw/gw_a.jsonl and never
// printed. State (cookies, installation id) goes to .secrets/live-state-a.

LIVE_GUILD :: Snowflake(1564227669971832975) // "fastcord test"
LIVE_CHANNEL :: Snowflake(1564227670806364343) // #general

@(private = "file")
live_enabled :: proc() -> bool {
	return os.get_env("FASTCORD_LIVE", context.temp_allocator) == "1"
}

@(private = "file")
repo_root :: proc() -> string {
	// tests run from the repo root (./build.sh test discord)
	return "."
}

@(private = "file")
live_token :: proc() -> string {
	path := strings.concatenate({repo_root(), "/.secrets/raw/gw_a.jsonl"}, context.temp_allocator)
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return ""
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		if !strings.contains(line, `"op":2`) && !strings.contains(line, `"op": 2`) do continue
		v, jerr := etf.from_json(line, context.temp_allocator)
		if jerr != .None do continue
		e := fmap(vmap(v), "etf")
		if fint(e, "op") != 2 do continue
		return strings.clone(fstr(fmap(e, "d"), "token"), context.temp_allocator)
	}
	return ""
}

@(private = "file")
wait_until :: proc(c: ^Client, timeout: time.Duration, cond: proc(c: ^Client, data: rawptr) -> bool, data: rawptr = nil) -> bool {
	deadline := time.tick_now()
	for time.tick_since(deadline) < timeout {
		client_poll(c)
		if cond(c, data) do return true
		time.sleep(50 * time.Millisecond)
	}
	return false
}

@(test)
live_login_send_react_delete :: proc(t: ^testing.T) {
	if !live_enabled() do return
	token := live_token()
	if !testing.expect(t, token != "", "no IDENTIFY token in .secrets/raw/gw_a.jsonl") do return
	c := client_create(Config{token = token, state_dir = strings.concatenate({repo_root(), "/.secrets/live-state-a"}, context.temp_allocator), initial_guild_id = LIVE_GUILD, initial_channel_id = LIVE_CHANNEL})
	defer client_destroy(c)
	c.transport.observer = proc(data: rawptr, host: string, req: http.Request, resp: ^http.Response, err: http.Error, start_ms: i64) {
		log.infof("%v %s %s %s -> %d", resp.version, req.method, host, req.path[:min(len(req.path), 60)], resp.status)
	}
	client_set_viewport(c, 1280, 720) // the app reports these (here: the captured window)
	client_set_accessibility(c, A11Y_PREFERS_COLOR_SCHEME_LIGHT)
	client_start(c)

	ok := wait_until(c, 30 * time.Second, proc(c: ^Client, _: rawptr) -> bool {return c.store.ready || c.store.connection == .Auth_Failed})
	if !testing.expect(t, ok && c.store.ready, "no READY") do return
	log.infof("READY: %d guilds, %d channels, %d users, %d private channels", len(c.store.guilds), len(c.store.channels), len(c.store.users), len(c.store.private_channels))
	for gid in c.store.guild_order {
		g := guild_get(&c.store, gid)
		log.infof("guild %v %q: %d channels", gid, g.name, len(g.channels))
	}
	g := guild_get(&c.store, LIVE_GUILD)
	if !testing.expect(t, g != nil, "test guild missing") do return
	for cid in guild_channels_sorted(&c.store, LIVE_GUILD) {
		ch := channel_get(&c.store, cid)
		log.infof("  #%s (%v)", ch.name, ch.kind)
	}

	time.sleep(1500 * time.Millisecond)
	select_channel(c, LIVE_GUILD, LIVE_CHANNEL, 50)
	ok = wait_until(c, 15 * time.Second, proc(c: ^Client, _: rawptr) -> bool {
		l, has := c.store.messages[LIVE_CHANNEL]
		return has && l.loaded
	})
	if !testing.expect(t, ok, "messages not loaded") do return
	log.infof("fetched %d messages", len(messages_get(&c.store, LIVE_CHANNEL)))

	time.sleep(2 * time.Second)
	typing_keystroke(c, LIVE_CHANNEL)
	time.sleep(2 * time.Second)
	client_poll(c)
	content := fmt.tprintf("fastcord live test %d", now_ms())
	nonce := send_message(c, LIVE_CHANNEL, content)
	Ctx :: struct {
		nonce:   Snowflake,
		content: string,
		id:      Snowflake,
	}
	ctx := Ctx{nonce = nonce, content = content}
	ok = wait_until(c, 15 * time.Second, proc(c: ^Client, data: rawptr) -> bool {
		x := cast(^Ctx)data
		for m in messages_get(&c.store, LIVE_CHANNEL) {
			if m.content == x.content && !m.pending && m.id != x.nonce {
				x.id = m.id
				return true
			}
		}
		return false
	}, &ctx)
	if !testing.expect(t, ok, "sent message never confirmed") do return
	log.infof("message %v confirmed", ctx.id)

	time.sleep(2 * time.Second)
	add_reaction(c, LIVE_CHANNEL, ctx.id, "👍")
	ok = wait_until(c, 15 * time.Second, proc(c: ^Client, data: rawptr) -> bool {
		x := cast(^Ctx)data
		l := &c.store.messages[LIVE_CHANNEL]
		i := message_index(l, x.id)
		return i >= 0 && len(l.messages[i].reactions) > 0 && l.messages[i].reactions[0].me
	}, &ctx)
	testing.expect(t, ok, "reaction not seen via MESSAGE_REACTION_ADD")

	time.sleep(2 * time.Second)
	delete_message(c, LIVE_CHANNEL, ctx.id)
	ok = wait_until(c, 15 * time.Second, proc(c: ^Client, data: rawptr) -> bool {
		x := cast(^Ctx)data
		return message_index(&c.store.messages[LIVE_CHANNEL], x.id) < 0
	}, &ctx)
	testing.expect(t, ok, "delete not observed")
	time.sleep(1 * time.Second)
}
