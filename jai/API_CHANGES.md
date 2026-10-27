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
