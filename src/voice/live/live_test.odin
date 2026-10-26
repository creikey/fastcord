// Live end-to-end voice test: accounts A and B (both our own code) join the
// same guild voice channel, A sends a 440 Hz tone, B checks the decoded
// audio, both compare DAVE privacy codes, then both leave.
// Gated by FASTCORD_LIVE=1. Tokens are read at test time from .secrets/raw
// captures and never printed.
//
//	FASTCORD_LIVE=1 ./build.sh test voice/live
package voice_live

import "core:fmt"
import "core:log"
import "core:math"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import dc "fc:discord"
import "fc:etf"
import "fc:voice"

// candidate (guild, voice channel) pairs, first one both accounts can see wins
CANDIDATES :: [][2]dc.Snowflake{
	{1546820558300258304, 1546820558950371411}, // test guild "General"
	{1564227669971832975, 1564227670806364345}, // "fastcord test" voice
}

@(private = "file")
live_enabled :: proc() -> bool {return os.get_env("FASTCORD_LIVE", context.temp_allocator) == "1"}

// token_a: the captured IDENTIFY in gw_a.jsonl
@(private = "file")
token_a :: proc() -> string {
	data, err := os.read_entire_file(".secrets/raw/gw_a.jsonl", context.temp_allocator)
	if err != nil do return ""
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		if !strings.contains(line, `"op":2`) do continue
		v, jerr := etf.from_json(line, context.temp_allocator)
		if jerr != .None do continue
		e := dc.fmap(dc.vmap(v), "etf")
		if dc.fint(e, "op") != 2 do continue
		return strings.clone(dc.fstr(dc.fmap(e, "d"), "token"), context.temp_allocator)
	}
	return ""
}

// token_b: the Authorization header of account B's captured REST requests
@(private = "file")
token_b :: proc() -> string {
	for name in ([]string{".secrets/raw/coldstart_b.jsonl"}) {
		data, err := os.read_entire_file(name, context.temp_allocator)
		if err != nil do continue
		s := string(data)
		key := `"Authorization":"`
		i := strings.index(s, key)
		if i < 0 do continue
		rest := s[i + len(key):]
		j := strings.index_byte(rest, '"')
		if j > 20 do return strings.clone(rest[:j], context.temp_allocator)
	}
	return ""
}

Side :: struct {
	name:     string,
	client:   ^dc.Client,
	conn:     ^voice.Conn,
	tone:     bool,
	phase:    f64,
	mu:       sync.Mutex,
	heard:    [dynamic]f32, // left channel of audio from the peer
	peer:     u64,
}

@(private = "file")
poll_until :: proc(sides: []^Side, timeout: time.Duration, cond: proc(s: ^Side) -> bool) -> bool {
	start := time.tick_now()
	for time.tick_since(start) < timeout {
		all := true
		for s in sides {
			dc.client_poll(s.client)
			if !cond(s) do all = false
		}
		if all do return true
		time.sleep(50 * time.Millisecond)
		free_all(context.temp_allocator)
	}
	return false
}

@(test)
live_voice_two_accounts :: proc(t: ^testing.T) {
	if !live_enabled() do return
	ta, tb := token_a(), token_b()
	if !testing.expect(t, ta != "" && tb != "", "tokens not found in .secrets/raw") do return
	testing.expect(t, ta != tb, "A and B tokens must differ")

	a := new(Side)
	b := new(Side)
	defer free(a)
	defer free(b)
	a.name, b.name = "A", "B"
	a.tone = true
	a.client = dc.client_create(dc.Config{token = ta, state_dir = ".secrets/live-state-a"})
	b.client = dc.client_create(dc.Config{token = tb, state_dir = ".secrets/live-state-voice-b"})
	defer dc.client_destroy(a.client)
	defer dc.client_destroy(b.client)
	dc.client_start(a.client)
	dc.client_start(b.client)
	sides := []^Side{a, b}
	ok := poll_until(sides, 40 * time.Second, proc(s: ^Side) -> bool {return s.client.store.ready || s.client.store.connection == .Auth_Failed})
	if !testing.expect(t, ok && a.client.store.ready && b.client.store.ready, "both READY") do return
	a.peer = u64(b.client.store.me)
	b.peer = u64(a.client.store.me)

	guild, channel: dc.Snowflake
	for cand in CANDIDATES {
		ga := dc.guild_get(&a.client.store, cand[0])
		gb := dc.guild_get(&b.client.store, cand[0])
		ch := dc.channel_get(&a.client.store, cand[1])
		if ga != nil && gb != nil && ch != nil && ch.kind == .Guild_Voice {
			guild, channel = cand[0], cand[1]
			break
		}
	}
	if guild == 0 {
		// any shared guild with a voice channel
		for gid in a.client.store.guild_order {
			if dc.guild_get(&b.client.store, gid) == nil do continue
			for cid in dc.guild_channels_sorted(&a.client.store, gid) {
				if ch := dc.channel_get(&a.client.store, cid); ch != nil && ch.kind == .Guild_Voice {
					guild, channel = gid, cid
					break
				}
			}
			if guild != 0 do break
		}
	}
	for sd in sides {
		log.infof("%s me=%v guilds=%d private=%d", sd.name, sd.client.store.me, len(sd.client.store.guilds), len(sd.client.store.private_channels))
		for gid in sd.client.store.guild_order {
			g := dc.guild_get(&sd.client.store, gid)
			log.infof("  %s guild %v %q channels=%d", sd.name, gid, g.name if g != nil else "?", len(g.channels) if g != nil else 0)
		}
	}
	if guild == 0 {
		// B shares no guild: a DM call between A and B (op 4 with guild_id null)
		for cid in b.client.store.private_channels {
			ch := dc.channel_get(&b.client.store, cid)
			if ch == nil || ch.kind != .DM do continue
			for r in ch.recipient_ids do if u64(r) == b.peer do channel = cid
		}
		if channel != 0 do log.infof("using DM call in channel %v", channel)
	}
	if !testing.expect(t, channel != 0, "no voice channel or DM shared by A and B") do return
	log.infof("voice channel %v in guild %v", channel, guild)

	time.sleep(1 * time.Second)
	dc.voice_join(a.client, guild, channel)
	time.sleep(1500 * time.Millisecond) // A joins first, B triggers the MLS add
	dc.voice_join(b.client, guild, channel)
	ok = poll_until(sides, 20 * time.Second, proc(s: ^Side) -> bool {
		_, _, have := dc.voice_server_info(s.client)
		return have
	})
	if !testing.expect(t, ok, "VOICE_SERVER_UPDATE for both") do return

	for s in sides {
		info, _, _ := dc.voice_server_info(s.client)
		opts := voice.Options {
			no_audio_devices = true,
			callback_data    = s,
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
		s.conn = voice.voice_connect(voice.Voice_Server_Info{
			endpoint = info.endpoint,
			token = info.token,
			guild_or_channel_id = u64(info.guild_or_channel_id),
			user_id = u64(info.user_id),
			session_id = info.session_id,
			channel_id = u64(info.channel_id),
			user_agent = s.client.id.platform.browser_user_agent,
		}, opts)
	}
	for s in sides {
		c := voice.wait_state(s.conn, .Connected, 10 * time.Second)
		st, code := voice.state(s.conn)
		testing.expectf(t, c, "%s voice connected (state %v code %d)", s.name, st, code)
	}
	// let DAVE establish and audio flow; keep the main gateways polled
	start := time.tick_now()
	for time.tick_since(start) < 8 * time.Second {
		for s in sides do dc.client_poll(s.client)
		time.sleep(50 * time.Millisecond)
		free_all(context.temp_allocator)
	}

	ea := voice.e2ee_status(a.conn, context.temp_allocator)
	eb := voice.e2ee_status(b.conn, context.temp_allocator)
	log.infof("A: dave v%d active=%v epoch=%d members=%d; B: dave v%d active=%v epoch=%d members=%d", ea.protocol_version, ea.active, ea.epoch, ea.members, eb.protocol_version, eb.active, eb.epoch, eb.members)
	testing.expect(t, ea.active && eb.active, "E2EE active on both")
	testing.expectf(t, ea.privacy_code != "" && ea.privacy_code == eb.privacy_code, "privacy codes match (%d / %d digits)", len(ea.privacy_code), len(eb.privacy_code))
	for s in sides {
		st := voice.get_stats(s.conn)
		log.infof("%s: ping %d ms rtt %d ms sent %d recv %d udp %d rtcp %d other_pt %d unknown_ssrc %d users %d transport_fail %d e2ee_fail %d jitter %.1f ms lost %d", s.name, st.ws_ping_ms, st.rtt_ms, st.packets_sent, st.packets_received, st.udp_datagrams, st.rtcp_received, st.other_pt, st.unknown_ssrc, st.remote_users, st.transport_failures, st.e2ee_failures, st.jitter.jitter_ms, st.jitter.lost)
	}
	testing.expect(t, voice.is_speaking(b.conn, b.peer), "B sees A speaking")

	sync.mutex_lock(&b.mu)
	heard := b.heard[:]
	n := len(heard)
	rms, freq := 0.0, 0.0
	if n > 9600 {
		w := heard[n - 9600 * 2:] if n > 19200 else heard[n - 9600:]
		acc := 0.0
		zc := 0
		for x, i in w {
			acc += f64(x) * f64(x)
			if i > 0 && (w[i - 1] < 0) != (x < 0) do zc += 1
		}
		rms = math.sqrt(acc / f64(len(w)))
		freq = f64(zc) / 2 * 48000 / f64(len(w))
	}
	sync.mutex_unlock(&b.mu)
	log.infof("B heard %d samples of A: rms %.3f, %.1f Hz", n, rms, freq)
	testing.expectf(t, rms > 0.05 && abs(freq - 440) < 30, "B decodes A's tone: rms %.3f freq %.1f", rms, freq)

	for s in sides {
		voice.voice_disconnect(s.conn)
		dc.voice_leave(s.client)
	}
	poll_until(sides, 2 * time.Second, proc(s: ^Side) -> bool {return false})
	delete(a.heard)
	delete(b.heard)
	_ = fmt.tprint
}
