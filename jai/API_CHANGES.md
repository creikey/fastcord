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
