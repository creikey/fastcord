Theme_Name :: enum u8 {
	Light;
	Ash;
	Dark;
	Onyx;
}
#scope_file

// Token values resolved from the official client's CSS (tools/probes/theme_tokens.js).
// Token values resolved from the official client's CSS (tools/probes/theme_tokens.js).
THEME_JSON := string.[
	#run load_file("../../assets/theme/light.json", #filepath),
	#run load_file("../../assets/theme/ash.json", #filepath),
	#run load_file("../../assets/theme/dark.json", #filepath),
	#run load_file("../../assets/theme/onyx.json", #filepath)
];
#scope_export

Theme :: struct {
	name: Theme_Name;
	tokens: Map(string, ui.Color);
}

theme_load :: (t: *Theme, name: Theme_Name) {
	for k: t.tokens { delete(k); }
	clear(*t.tokens);
	t.name = name;
	v, err := json.parse(THEME_JSON[name], allocator = temp);
	if err != .None { return; }
	obj := ifx v.kind == .Map then v.map else .{};
	for k, val: obj {
		arr := ifx val.kind == .List then val.list else zero(type_of(val.list));
		if len(arr) != 4 { continue; }
		c: ui.Color;
		for i: 0..2 { c.component[i] = cast(float32)(ifx arr[i].kind == .Float then arr[i].f else cast(float64)(ifx arr[i].kind == .Int then arr[i].i else 0)) / 255; }
		c.w = cast(float32)(ifx arr[3].kind == .Float then arr[3].f else cast(float64)(ifx arr[3].kind == .Int then arr[3].i else 1));
		at(*t.tokens, clone(k)).* = c;
	}
}

// Color for a CSS token like "--text-default". Missing tokens are magenta so they stand out.
tok :: (t: *Theme, name: string) -> ui.Color {
	{ c, ok := map_find(t.tokens, name);
	if ok { return c; } }
	return .{1, 0, 1, 1};
}

