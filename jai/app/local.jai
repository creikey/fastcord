// Local compat helpers for the Odin port (candidates for fc).
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

// Int2: Odin [2]int, used with .x / .y swizzles.
Int2 :: struct { x, y: int; }
operator == :: (a: Int2, b: Int2) -> bool { return a.x == b.x && a.y == b.y; }

// all4: Odin broadcast of a scalar into [4]f32 (corner radii).
all4 :: inline (v: float32) -> [4]float32 { return .[v, v, v, v]; }

// card: Odin card(bit_set), the number of flags set.
card :: (f: $E) -> int { n := 0; x := cast(u64) f; while x { n += cast(int) (x & 1); x >>= 1; } return n; }

// bytes_equal: Odin struct == for padding-free structs.
bytes_equal :: (a: $T, b: T) -> bool { aa, bb := a, b; return memcmp(*aa, *bb, size_of(T)) == 0; }

operator == :: (a: gfx.Diag, b: gfx.Diag) -> bool {
	return a.dead_tex_draws == b.dead_tex_draws && a.last_dead_tex == b.last_dead_tex && a.tex_create_fails == b.tex_create_fails && a.present_fails == b.present_fails && a.last_hresult == b.last_hresult && a.device_removed == b.device_removed && a.atlas_resets == b.atlas_resets;
}

// Name_Px_Map: Odin map[struct{string, int}]gfx.Texture (struct keys need explicit hash/compare in Jai).
Name_Px :: struct { name: string; px: int; }
Name_Px_Map :: Table(Name_Px, gfx.Texture, given_hash_function = (k: Name_Px) -> u32 { return get_hash(k.name, get_hash(k.px)); }, given_compare_function = (a: Name_Px, b: Name_Px) -> bool { return a.name == b.name && a.px == b.px; });

// Module-named struct fields (app.ui, upd.thread) shadow the module in their own declaration.
Ui_State :: ui.State;
Thread :: thread.Thread;
operator == :: (a: ui.Rect, b: ui.Rect) -> bool { return a.x0 == b.x0 && a.y0 == b.y0 && a.x1 == b.x1 && a.y1 == b.y1; }

// fc_utf8 is imported by name, so its rune iterator needs an alias here (for r: utf8.runes(s)).
for_expansion :: utf8.for_expansion;
