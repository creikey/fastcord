// TEMPORARY Odin-port compat (deleted when the last caller is rewritten).
is_null :: inline (x: $T) -> bool {
	#if type_info(T).type == .ARRAY || type_info(T).type == .STRING return x.data == null;
	else #if type_info(T).type == .STRUCT return x.allocator.proc == null;
	else return x == null;
}

// PHASE-1 TEMP: fc Map verbs on discord's Hash_Table Tables (removed with fc).
map_find_ptr :: inline (m: *Table, k: m.Key_Type) -> *m.Value_Type, bool { p := table_find_pointer(m, k); return p, p != null; }
map_find :: inline (m: Table, k: m.Key_Type) -> m.Value_Type, bool { mm := m; p := table_find_pointer(*mm, k); if p return p.*, true; z: m.Value_Type; return z, false; }
get :: inline (m: Table, k: m.Key_Type) -> m.Value_Type { mm := m; p := table_find_pointer(*mm, k); if p return p.*; z: m.Value_Type; return z; }
has :: inline (m: Table, k: m.Key_Type) -> bool { mm := m; return table_find_pointer(*mm, k) != null; }
at :: inline (m: *Table, k: m.Key_Type) -> *m.Value_Type { return find_or_add(m, k); }
len :: inline (m: Table) -> int { return m.count; }
map_set :: inline (m: *Table, k: m.Key_Type, v: m.Value_Type) { table_set(m, k, v); }
delete_key :: inline (m: *Table, k: m.Key_Type) { table_remove(m, k); }
clear :: (m: *Table) { table_reset_keeping_memory(m); }
delete :: (m: Table) { mm := m; deinit(*mm); }
reserve :: (m: *Table, n: int) { table_ensure_space(m, n); }

// card: Odin card(bit_set), the number of flags set.
card :: (f: $E) -> int { n := 0; x := cast(u64) f; while x { n += cast(int) (x & 1); x >>= 1; } return n; }

// bytes_equal: Odin struct == for padding-free structs.
bytes_equal :: (a: $T, b: T) -> bool { aa, bb := a, b; return memcmp(*aa, *bb, size_of(T)) == 0; }

operator == :: (a: gfx.Diag, b: gfx.Diag) -> bool {
	return a.dead_tex_draws == b.dead_tex_draws && a.last_dead_tex == b.last_dead_tex && a.tex_create_fails == b.tex_create_fails && a.present_fails == b.present_fails && a.last_hresult == b.last_hresult && a.device_removed == b.device_removed && a.atlas_resets == b.atlas_resets;
}

// Module-named struct field (upd.thread) shadows the module in its own declaration.
Thread :: thread.Thread;

// fc_utf8 is imported by name, so its rune iterator needs an alias here (for r: utf8.runes(s)).
for_expansion :: utf8.for_expansion;
