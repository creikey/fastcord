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
