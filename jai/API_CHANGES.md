# Exported-API changes from the idiomatic rewrite (for updating callers; deleted when the rewrite is done)

## locks
- cond_wait_with_timeout(c, m, timeout_ms: s64) (was a time.Duration in ns): `500 * time.Millisecond` -> `500`.
- join(t: *Thread) takes Jai's Thread module Thread: allocate with New(Thread), thread_init + thread_start;
  join waits, thread_deinit and free(t).
- Cond is locks.Cond; Mutex has `state` (was `impl`). Both zero-initialised.
- New locks.current_thread_id() -> int (OS thread id), replaces sync.current_thread_id (app/watchdog.jai).
- UI_LOCK_WAIT_REPORT -> UI_LOCK_WAIT_REPORT_MS :: 16.

## netio
- Stream.set_timeout: (data: *void, timeout_ms: s64); netio.set_timeout(s, timeout_ms). Layered streams (tls) update theirs.
- DIAL_IO_TIMEOUT -> DIAL_IO_TIMEOUT_MS :: 20_000. Tcp.sock is Socket's Socket. read_full removed;
  tcp_set_timeout private (use set_timeout(tcp_stream(t), ms)).

## prof
- Sampler: interval -> interval_ns, elapsed -> elapsed_ns; thr is an embedded Thread plus running: bool.
- Zones.origin, Zone_Mark.start are Apollo_Time. each_sample removed; resolve_symbols, Symbol private.

## platform_objc
- lib / Foundation no longer exported; rest unchanged.

## audio
- Removed: get_volume, set_muted, stats/Stats, device_available, is_running, source_free_frames, delete_devices,
  get_voice_processing, kAudioFormatFlagIsNonInterleaved. OUTPUT_IDLE_STOP -> OUTPUT_IDLE_STOP_SECONDS.
- ring_init/ring_destroy take no allocator. f32_bits/bits_f32 private; CoreAudio internals private (media keeps
  AudioStreamBasicDescription, AudioBuffer, AudioBufferList, fourcc, kAudioFormat*).
- list_devices returns []Device_Info from the given allocator.

## imagefmt
- Error.Out_Of_Memory removed. decode(data, allocator, max_pixels, first_only := false).

## vector
- rasterize_layers(icon, w, h, layers, allocator) -> rasterize(icon, w, h, allocator, layers := .Primary).
- Layers alias removed (use Layer); Vector2/Vector4 aliases removed (Math's types). rasterizer_init returns nothing.
- Rasterizer flattened {w, h, stride, acc, pts, polys, pool}. path_clear/path_destroy removed. mat_mul/mat_apply exported.

## lottie
- load(data) -> *Animation (null on bad JSON); Error enum removed. player_init returns nothing.
- Animation.arena -> Animation.pool: Flat_Pool; Player.frame is a Flat_Pool, Player.falloc removed. eval/eval_shape private.
- Callers: app/pickers_lottie.jai:44 and :89.

## platform
- Mods alias removed: use Mod (Event.mods is Mod; same layout, app/glue.jai's transmute still works).
- Removed (no callers): get_cursor, display_refresh_hz, frame_requested, request_quit, headless_resize, native_view, notify_supported.
- macOS internals no longer exported: msg/Void/Id/cls/sel, NS, CV, CVDisplayLink*, NSDefaultRunLoopMode/NSRunLoopCommonModes, nsstr/odin_str.
- Unchanged for gfx: dpi_scale, framebuffer_size, is_headless, native_metal_layer, native_window, set_frame_wait_handle (Windows).
- Windows backend now uses Jai's Windows / Windows_Registry / Windows_Utf8 modules (it imported fc_windows/fc_utf16, which do not exist, so it never compiled); type-checks with os_target = .WINDOWS.
## gfx
- vec.jai removed: its exported Vector2/Vector4 operators are gone (gfx keeps a module-private per-component `/`).
- mtl_darwin.jai removed: MTL, MTLCreateSystemDefaultDevice, CFStringGetCString no longer exported.
- No more re-exported import aliases (gfx.math, gfx.mem, gfx.bytes, gfx.os, gfx.utf8, gfx.objc, gfx.platform...).
- Private backend procs renamed (_backend_* -> backend_*, _font_*/_shape/_rasterize -> native_*); not exported.
- Public procs, types and constants otherwise unchanged (Texture, Texture_Format, Yuv_Matrix, Rect, Color,
  cf_type_dictionary_callbacks, native_device, texture_*, video, shape, draw_run, read_pixels, write_png...).
## ui
- selection_text(fetch := null, allocator := temp) -> selection_text(allocator := temp): the unused fetch parameter is gone (no caller passed it).
- STACK_MAX removed (unused). State.arenas is [2]Flat_Pool (was the fc_mem Dynamic_Arena alias of the same type).
- vec.jai's exported Vector2/Vector4 operators removed: ui divides no vectors, so Math's operators are used as-is.
- Callers: none of app's ui calls change (Box_Flags / Mods aliases kept).
## media
- Byte_Source.wait: (user, have, timeout: time.Duration) -> (user, have, timeout_ms: s64).
- be16/be24/be32/be64/le16/le32/le64(b) -> (b: []u8, i := 0): read at b[i] (was a sliced view).
- fourcc alias removed (use audio.fourcc); CMTime no longer exported.
- Player.thread is an embedded Thread (was *fc_thread.Thread); Player.pending_seek removed (unused).
- Rest unchanged (player_*, source_*, growing_*, demux_*, probe, audio_waveform, audio/video decoder procs).

## Gotcha (all modules)
- After push_allocator(...), a local or parameter named `allocator` in the same procedure means the pushed one
  (Basic's macro parameter is named allocator): read allocator arguments before pushing.

## Allocator parameters (etf, zstd, brotli, opus, protobuf, voice_dave, voice_mls)
- Removed throughout; callers pass `,, alloc` (e.g. `etf.decode(x,, a)`, `zstd.decompress(src, max_out,, temp)`).

## inflate (replaces fc_zlib / fc_gzip)
- zlib.Inflater -> inflate.Inflater; inflater_init(*f, .Raw/.Zlib) -> inflate.init(*f, .RAW/.ZLIB/.GZIP);
  inflater_destroy -> inflate.destroy; feed(*f, src, *out, max_out) -> ended, ok (same).
- zlib.inflate(input, *bytes.Buffer, raw, expected) / gzip.load(input, *buf) -> inflate.inflate(data, kind, max_out := -1) -> []u8, bool.

## crypto (replaces fc_crypto and the per-algorithm fc_* modules)
- random_bytes(b), zero(b) / zero(*x), constant_time_equal(a, b) -> bool.
- sha1/md5/sha256(data) -> [20]u8/[16]u8/[32]u8 (no streaming: concatenate first, e.g. tls/trust_cache).
- hmac_sha256(key, msg) -> [32]u8 (key first). hkdf_extract(salt, ikm) -> [32]u8; hkdf_expand(prk, info, out) -> bool;
  pbkdf2_sha256(pw, salt, iters, out) -> bool.
- Aead: aead_init(*a, .AES_GCM | .XCHACHA20_POLY1305, key) -> bool; aead_destroy; seal(*a, dst, tag, nonce, aad, pt) -> bool;
  open(*a, dst, nonce, aad, ct, tag) -> bool. aes_ctr(key, iv16, src, dst).
- P-256 on raw bytes: p256_public(priv) -> [65]u8, bool; p256_generate() -> priv, pub, ok; p256_valid_public(pub);
  p256_ecdh(priv, pub) -> [32]u8, bool; p256_sign(priv, msg) -> []u8 (DER); p256_verify(pub, msg, sig) -> bool.

## etf
- decode(data), from_json(text), encode(v), map_builder(cap), big_from_u64(x): allocator via `,,`.
- to_json / write_json_string take *String_Builder (Basic). Removed: Decode_Options, etf_to_json, destroy, encode_into,
  Error.Out_Of_Memory; VERSION, Tag private.

## zstd / brotli / opus / protobuf
- zstd: stream_init(d, max_window); decompress(input, max_out, max_window). stream_at_frame_boundary removed.
- brotli: decompress(input, max_out).
- opus: encoder_create(fs, ch, app), decoder_create(fs, ch), encoder_destroy(e), decoder_destroy(d).
- protobuf: packed_fixed64(b).

## voice_dave / voice_mls
- voice_dave: session_take_outgoing(s), session_status(s), session_verification_code(s, user), session_user_ids(s),
  ratchet_init(r, base) lose the allocator (use `,, temp`); Session.recognized/transitions/decryptors/roster are Tables.

## tls
- connect(under, cfg, allocator) -> *Session, netio.Error  ->  connect(under, cfg) -> *Session, netio.Error, Error (third:
  the detailed reason); the Session comes from context.allocator. last_error() and the #add_context field removed.
- ensure_init removed: new_ssl/connect initialise on first use. New set_context(ssl, *#Context): an SSL driven outside a
  Session (QUIC) must name the context its BoringSSL callbacks run in, on the thread that drives it (quic does).
- CHACHA20_IMPL removed (it was fc_chacha20's; voice/rtp.jai:74 should use crypto). CHROME_TLS12_CIPHERS private.
- TRUST_CACHE_TTL -> TRUST_CACHE_TTL_MS. OPENSSL_strdup binding removed, OPENSSL_zalloc added.

## http
- Allocator parameters removed; pass `,, a`: h1_init(c, s, limits), h2_connect(s, cfg), ws_connect(s, req, opts),
  ws_attach(s, opts), ws_accept_for_key(key). Callers: discord/transport.jai:284,299,362, gateway.jai:485,
  remote_auth.jai:482, app/update.jai:61.
- Decoder_Proc (src, dst: *[..]u8, max_out) -> Error  ->  (src, max_out) -> []u8, Error, the result from
  context.allocator (decode_body passes the response's). Callers: discord/transport.jai:86-98 (br_decoder/zstd_decoder:
  `out, err := brotli.decompress(src, max_out); return out, ifx err then .Decompress else .None;`).
- New make_response(version): an empty Response whose arrays and strings use context.allocator.
- pipe_make(read_timeout: Duration, max_chunk) -> pipe_make(read_timeout_ms := 10_000, max_chunk := 0).
- Now private: header_has_token, the Reader procs (reader_init/destroy, read_some, read_exact, consume, buffered,
  map_net_error), h1_serialize_request, h1_write_request, h1_read_head, h1_read_response, Hpack_Encoder/hpack_*, WS_GUID,
  H2_Stream and the nghttp2/wslay/picohttpparser bindings. nghttp2_hd_* bindings and remove_range removed.
- Ws_Conn.ctx (wslay's context) -> Ws_Conn.wslay; Ws_Conn.inflater is an inflate.Inflater. H2_Conn.streams is a
  Table(s32, *H2_Stream); its times are Apollo_Time.

## quic
- connect(host, port, addr) -> connect(host, port := 443); dial removed (connect is dial + wait).
- request(c, req, allocator) -> request(c, req) with `,, a` (e.g. discord/transport.jai:433). chrome_transport_params(rtt_us)
  and cached_rtts() take `,, a` too.
- Conn: sock/wake_sock are Udp_Socket (Jai Socket), peer/local Udp_Addr, io a Jai Thread, streams a Table; new ssl, ctx.
  init_quic/quic_once removed (the QUIC SSL_CTX is made on first connect).

## quic_altsvc
- record(c, host, value), usable(c, host), mark_broken(c, host): the test-only now_ parameter removed (wall clock).
- parse(value, allocator) -> parse(value), into temp.
- Cache.entries / Cache.conns are Tables (discord/transport.jai:404: `found, _ := table_find(*t.alt.conns, host)`); new
  Cache.races. Entry.expires / broken_until are Apollo_Time (zero = not broken).
- BROKEN_INITIAL -> BROKEN_INITIAL_MS, BROKEN_MAX -> BROKEN_MAX_MS, DELAY_MAIN_JOB_MAX -> DELAY_MAIN_JOB_MAX_NS.
- connect's race jobs run on Jai Threads joined by a later connect or by destroy, which now waits for a race still running
  (the Odin code left it running against a freed Cache).

## voice
- Allocator parameters removed; pass `,, a`: speaking_users(c) (app/view_voice.jai:184: `voice.speaking_users(vc.conn,, temp)`),
  e2ee_status(c) (app/view_voice.jai:254: `voice.e2ee_status(vc.conn,, temp).active`), privacy_code(c), verification_code(c, user).
- wait_state(c, s, timeout: Duration) -> wait_state(c, s, timeout_ms: s64).
- Transport_Crypto is {mode, aead: crypto.Aead, init} (key/gcm/cha removed; the crypto module does both AEADs).
- get_u16/get_u32/put_u16/put_u32 read/write at b[i] (b, [v,] i := 0) instead of taking a sliced view.
- Conn: udp is a Socket, server_ep a Udp_Addr, thread handles *Thread (Jai Thread); the allocator field is gone (threads
  inherit context.allocator from voice_connect). Vad, Jitter_Buffer, User_Settings have default initializers.
- uuid4() takes no allocator; snowflake(v) returns Str (a JSON-string part for json_msg). jget/jint/jstr/jsnow/jarr take etf.Value.
- opus_codec.jai merged into codec.jai (same procedures).

## tool_capture_cdp
- browser_ws_url(port) returns its string in context.allocator (allocator parameter removed); quote(s) / to_json(v) always use temp.
- call/call_value(c, method, params, session, timeout_ms: s64 = 30_000) and next(c, timeout_ms) take milliseconds (were Durations).
- Client.s removed; Client.mu/cond/wmu are locks, reader a *Thread.

## tool_scrub / tool_trafficdiff / tool_capture
- No API used elsewhere. scrub: convert(raw, env, netlogs := string.["", ""]); Ctx's maps are Tables; local.jai removed.
