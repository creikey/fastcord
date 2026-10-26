package voice_live

import "core:log"
import "core:math"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import dc "fc:discord"
import "fc:voice"

// Guild voice: A's private test guild (tests/scenarios/env TGUILD). B joins
// the guild once through an invite created by A (code cached in
// .secrets/tguild_invite.txt), then: both in TVOICE -> E2EE + audio, B leaves
// (MLS remove / sole member reset for A), B rejoins -> new group, audio again.

TGUILD :: dc.Snowflake(1564227669971832975)
TTEXT :: dc.Snowflake(1564227670806364343)
TVOICE :: dc.Snowflake(1564227670806364345)
INVITE_CACHE :: ".secrets/tguild_invite.txt"

@(private = "file")
pump :: proc(sides: []^Side, d: time.Duration) {
	start := time.tick_now()
	for time.tick_since(start) < d {
		for s in sides do dc.client_poll(s.client)
		time.sleep(50 * time.Millisecond)
		free_all(context.temp_allocator)
	}
}

side_options :: proc(s: ^Side) -> voice.Options {
	return voice.Options {
		no_audio_devices = true,
		callback_data = s,
		capture = proc(data: rawptr, out: []f32) -> int {
			s := cast(^Side)data
			for i in 0 ..< len(out) {
				out[i] = 0
				if s.tone {
					out[i] = 0.3 * f32(math.sin(s.phase))
					s.phase += 2 * math.PI * 440 / 48000
				}
			}
			return len(out)
		},
		playback = proc(data: rawptr, user_id: u64, pcm: []f32) {
			s := cast(^Side)data
			if user_id != s.peer do return
			sync.mutex_lock(&s.mu)
			for i := 0; i < len(pcm); i += 2 do append(&s.heard, pcm[i])
			sync.mutex_unlock(&s.mu)
		},
	}
}

side_connect :: proc(s: ^Side) -> bool {
	info, ver, ok := dc.voice_server_info(s.client)
	if !ok do return false
	s.version = ver
	s.conn = voice.voice_connect(voice.Voice_Server_Info {
		endpoint = info.endpoint,
		token = info.token,
		guild_or_channel_id = u64(info.guild_or_channel_id),
		user_id = u64(info.user_id),
		session_id = info.session_id,
		channel_id = u64(info.channel_id),
		user_agent = s.client.id.platform.browser_user_agent,
	}, side_options(s))
	return voice.wait_state(s.conn, .Connected, 10 * time.Second)
}

// tone_heard: rms / frequency of the last 200 ms B heard from the peer.
tone_heard :: proc(s: ^Side) -> (n: int, rms, freq: f64) {
	sync.mutex_lock(&s.mu)
	defer sync.mutex_unlock(&s.mu)
	n = len(s.heard)
	if n < 9600 do return
	w := s.heard[n - 9600:]
	acc := 0.0
	zc := 0
	for x, i in w {
		acc += f64(x) * f64(x)
		if i > 0 && (w[i - 1] < 0) != (x < 0) do zc += 1
	}
	return n, math.sqrt(acc / f64(len(w))), f64(zc) / 2 * 48000 / f64(len(w))
}

@(private = "file")
ensure_member :: proc(t: ^testing.T, a, b: ^Side) -> bool {
	if dc.guild_get(&b.client.store, TGUILD) != nil do return true
	code := ""
	if data, err := os.read_entire_file(INVITE_CACHE, context.temp_allocator); err == nil do code = strings.trim_space(string(data))
	if code == "" {
		inv := dc.create_invite(a.client, TTEXT, allocator = context.temp_allocator)
		log.infof("create invite: status %d", inv.status)
		if !inv.ok do return false
		code = inv.code
		_ = os.write_entire_file(INVITE_CACHE, transmute([]byte)code)
	}
	res := dc.resolve_invite(b.client, code, context.temp_allocator)
	log.infof("resolve invite: status %d guild %v", res.status, res.guild_id)
	if !res.ok do return false
	acc := dc.accept_invite(b.client, res, allocator = context.temp_allocator)
	log.infof("accept invite: status %d", acc.status)
	if !acc.ok do return false
	start := time.tick_now()
	for time.tick_since(start) < 15 * time.Second {
		dc.client_poll(a.client)
		dc.client_poll(b.client)
		if dc.guild_get(&b.client.store, TGUILD) != nil do return true
		time.sleep(50 * time.Millisecond)
	}
	return false
}

@(private = "file")
check_pair :: proc(t: ^testing.T, a, b: ^Side, phase: string) {
	ea := voice.e2ee_status(a.conn, context.temp_allocator)
	eb := voice.e2ee_status(b.conn, context.temp_allocator)
	log.infof("[%s] A: dave v%d active=%v epoch=%d members=%d | B: active=%v epoch=%d members=%d", phase, ea.protocol_version, ea.active, ea.epoch, ea.members, eb.active, eb.epoch, eb.members)
	testing.expectf(t, ea.active && eb.active && ea.members == 2, "[%s] E2EE active on both", phase)
	testing.expectf(t, ea.privacy_code != "" && ea.privacy_code == eb.privacy_code, "[%s] privacy codes match", phase)
	n, rms, freq := tone_heard(b)
	log.infof("[%s] B heard %d samples: rms %.3f %.1f Hz", phase, n, rms, freq)
	testing.expectf(t, rms > 0.05 && abs(freq - 440) < 30, "[%s] B decodes A's tone", phase)
}

@(test)
live_voice_guild_leave_rejoin :: proc(t: ^testing.T) {
	if !live_enabled() do return
	ta, tb := token_a(), token_b()
	if !testing.expect(t, ta != "" && tb != "", "tokens not found") do return
	a := new(Side)
	b := new(Side)
	defer free(a)
	defer free(b)
	a.name, b.name, a.tone = "A", "B", true
	a.client = dc.client_create(dc.Config{token = ta, state_dir = ".secrets/live-state-a"})
	b.client = dc.client_create(dc.Config{token = tb, state_dir = ".secrets/live-state-voice-b"})
	defer dc.client_destroy(a.client)
	defer dc.client_destroy(b.client)
	dc.client_start(a.client)
	dc.client_start(b.client)
	sides := []^Side{a, b}
	start := time.tick_now()
	for time.tick_since(start) < 40 * time.Second && !(a.client.store.ready && b.client.store.ready) do pump(sides, 100 * time.Millisecond)
	if !testing.expect(t, a.client.store.ready && b.client.store.ready, "both READY") do return
	a.peer, b.peer = u64(b.client.store.me), u64(a.client.store.me)
	if !testing.expect(t, ensure_member(t, a, b), "B is a member of TGUILD") do return

	// 1. both join
	dc.voice_join(a.client, TGUILD, TVOICE)
	pump(sides, 1500 * time.Millisecond)
	testing.expect(t, side_connect(a), "A connected")
	dc.voice_join(b.client, TGUILD, TVOICE)
	pump(sides, 1500 * time.Millisecond)
	testing.expect(t, side_connect(b), "B connected")
	pump(sides, 7 * time.Second)
	check_pair(t, a, b, "join")
	first := voice.e2ee_status(a.conn).privacy_code
	defer delete(first)

	// 2. B leaves: A gets the remove proposal / sole member reset
	voice.voice_disconnect(b.conn)
	b.conn = nil
	dc.voice_leave(b.client)
	pump(sides, 4 * time.Second)
	ea := voice.e2ee_status(a.conn, context.temp_allocator)
	sa, code := voice.state(a.conn)
	log.infof("[alone] A state %v code %d dave v%d active=%v epoch=%d members=%d", sa, code, ea.protocol_version, ea.active, ea.epoch, ea.members)
	testing.expect(t, sa == .Connected, "A stays connected when B leaves")
	testing.expect(t, ea.members <= 1, "B removed from A's group")

	// 3. B rejoins: new group
	sync.mutex_lock(&b.mu)
	clear(&b.heard)
	sync.mutex_unlock(&b.mu)
	dc.voice_join(b.client, TGUILD, TVOICE)
	start = time.tick_now()
	for time.tick_since(start) < 15 * time.Second {
		pump(sides, 100 * time.Millisecond)
		if _, ver, ok := dc.voice_server_info(b.client); ok && ver != b.version do break
	}
	testing.expect(t, side_connect(b), "B reconnected")
	pump(sides, 7 * time.Second)
	check_pair(t, a, b, "rejoin")
	second := voice.e2ee_status(a.conn).privacy_code
	defer delete(second)
	testing.expect(t, first != second, "new group after rejoin has a new privacy code")
	for s in sides {
		st := voice.get_stats(s.conn)
		log.infof("%s: rtt %d ms sent %d recv %d e2ee_fail %d lost %d", s.name, st.rtt_ms, st.packets_sent, st.packets_received, st.e2ee_failures, st.jitter.lost)
	}

	for s in sides {
		voice.voice_disconnect(s.conn)
		dc.voice_leave(s.client)
	}
	pump(sides, 2 * time.Second)
	delete(a.heard)
	delete(b.heard)
}
