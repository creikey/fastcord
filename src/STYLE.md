# Jai style for fastcord

fastcord is plain, idiomatic Jai: Jai's own modules (`/opt/jai/modules`), Jai semantics, the style of
`/opt/jai/how_to`. It was ported from Odin; wire bytes, timing and the settings file stay as they were.

## Rules

- **Jai modules first.** Use Basic, String, Hash_Table, Math, File,
  File_Utilities, Thread, Atomics, Process, Socket, Sort, Random, Base64, Unicode, POSIX... directly.
- **No Odin emulation.** No `sub`/`sub_from`/`len`/`get`/`at`/`Map`/`make_slice`/`make_dynamic`/`clone`/
  `transmute`/`zero`/`or_else`/`failed`/`has`/Odin printf verbs. Write the Jai way:
  - slices: `slice(s, start, count)`, `array_view(a, start, count)`, `advance(*s, n)`; `.count`;
  - arrays: `array_add`, `array_reserve`, `array_resize`, `array_insert_at`, `array_ordered_remove_by_index`,
    `array_copy`, `array_free`, `array_reset`, `NewArray(n, T)`, `peek`, `pop`;
  - strings (String module): `begins_with`, `ends_with`, `contains`, `find_index_from_left/right`, `split`,
    `join`, `trim`, `to_lower_copy`, `replace`, `copy_string`, `compare`; parse with `string_to_int`,
    `parse_int`, `string_to_float`;
  - formatting: `print`, `tprint`, `sprint` with `%`; `formatInt(x, base = 16, minimum_digits = 2)`,
    `formatFloat(x, trailing_width = 2)`; `String_Builder` with `append`, `print_to_builder`,
    `builder_to_string`;
  - hash maps: `Table(K, V)`: `table_find_pointer`, `table_find` (returns success first), `table_set`,
    `table_add`, `table_remove`, `find_or_add`, `table_reset`, `deinit`; iterate `for value, key: table`.
    Keys need `==` and a hash: give struct/array keys a `given_hash_function`/`given_compare_function`.
- **Allocation, Jai's way.** `context.allocator` by default; pass allocators with `,,`
  (`copy_string(s,, a)`, `New(T,, a)`, `NewArray(n, T,, a)`, `array_copy(x,, a)`) or `push_allocator(a)`.
  `temp` is per thread and reset by its owner (`reset_temporary_storage()` at the end of a frame or job):
  use it only for data that dies before that reset on the same thread. Anything kept across a reset or
  handed to another thread gets a real allocator (heap, or an owned Flat_Pool freed with its owner). Do not
  build allocators that imitate Odin's temp allocator.
- **Errors**: return `bool`, an `enum` (`.None` = ok) or a small struct. No pointer-as-error tricks.
- **Threads and locks**: `Thread` module threads (`thread_init`, `thread_start`, `thread_is_done`,
  `thread_deinit`; each thread gets its own temporary storage). fastcord's own `locks` module is the only
  mutex/cond API (checked, zero-initialised); no raw `Thread.Mutex` elsewhere.
- **C callbacks** (`#c_call`) run inside a library call made from Jai: store `*context` in the object passed
  as user data right before that call (or at creation if the same thread always drives it) and
  `push_context obj.ctx.* { ... }` in the callback. No thread-local context registries.
- **Time**: Basic's `current_time_monotonic()`, `current_time_consensus()`, `Apollo_Time`,
  `to_milliseconds`, `to_nanoseconds`, `seconds_to_apollo`, `to_calendar`/`calendar_to_apollo`,
  `sleep_milliseconds`. Durations in this code base are plain `s64` milliseconds or nanoseconds named
  `*_ms`/`*_ns`.
- **Files and processes**: File (`read_entire_file`, `write_entire_file`, `file_open`, `file_write`...),
  File_Utilities (`visit_files`, `file_exists`), `make_directory_if_it_does_not_exist`, Process
  (`run_command`, `create_process`).
- **JSON**: fastcord's `etf` module (`etf.from_json`, `etf.to_json`, `etf.Value`) for every JSON need.
- **fastcord-owned replacements** for what Jai lacks: `inflate` (Wuffs DEFLATE/zlib/gzip), `crypto`
  (BoringSSL: hashes, HMAC/HKDF/PBKDF2, AES-GCM, XChaCha20-Poly1305, AES-CTR, P-256 ECDH/ECDSA, random).
  Their APIs are plain procedures (`crypto.sha256(data) -> [32]u8`), not Odin-shaped contexts.
- **Operators**: Jai puts `& | ^ << >>` on one level above `*` and `+`, and `cast(T) x << 8` casts the whole
  shift: parenthesize every mixed bitwise expression. Casts truncate (bounds checks are off).
- **Shorter is better**: delete dead code and transpiler leftovers (`__r1, __r2 :=` forwarding, `{ x := ...;
  if ... }` init blocks, `#scope_file`/`#scope_export` churn), merge one-use helpers, prefer `ifx`, `for`
  with `it`, `using` where it reads well. Keep comments that explain why; drop ones that restate code.

## Gates

`jai build.jai - module <name>` compiles a module (every procedure type-checked). `jai build.jai - check-full` runs
the offline traffic-parity tests, the headless UI scripts and sweep, the bench budget and the secrets scan.
