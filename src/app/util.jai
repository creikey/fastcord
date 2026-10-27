// Small helpers shared by every view.

// Corner radii: one value for all four corners.
all4 :: inline (v: float32) -> [4]float32 { return .[v, v, v, v]; }

// Integer pixel size.
Int2 :: struct { x, y: int; }
operator == :: (a: Int2, b: Int2) -> bool { return a.x == b.x && a.y == b.y; }

operator == :: (a: ui.Rect, b: ui.Rect) -> bool { return a.x0 == b.x0 && a.y0 == b.y0 && a.x1 == b.x1 && a.y1 == b.y1; }

// Texture caches keyed by (name, pixel size).
Name_Px :: struct { name: string; px: int; }
Name_Px_Map :: Table(Name_Px, gfx.Texture, given_hash_function = (k: Name_Px) -> u32 { return get_hash(k.name, get_hash(k.px)); }, given_compare_function = (a: Name_Px, b: Name_Px) -> bool { return a.name == b.name && a.px == b.px; });

// App.ui would shadow the ui module inside its own declaration.
Ui_State :: ui.State;
