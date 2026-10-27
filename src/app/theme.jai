Theme_Name :: enum u8 {
	Light;
	Ash;
	Dark;
	Onyx;
}

Theme :: struct {
	name: Theme_Name;
	tokens: Table(string, ui.Color);
}

theme_load :: (t: *Theme, name: Theme_Name) {
	for t.tokens free(it_index);
	table_reset(*t.tokens);
	t.name = name;
	v, err := etf.from_json(THEME_JSON[name],, temp);
	if err != .None || v.kind != .Map return;
	for v.map {
		arr := it.value.list;
		if it.value.kind != .List || arr.count != 4 continue;
		c: ui.Color;
		for i: 0..3 c.component[i] = cast(float32) number(arr[i], ifx i == 3 then 1.0 else 0.0);
		for i: 0..2 c.component[i] /= 255;
		table_set(*t.tokens, copy_string(it.key.s), c);
	}
}

// Color for a CSS token like "--text-default". Missing tokens are magenta so they stand out.
tok :: (t: *Theme, name: string) -> ui.Color {
	c := table_find_pointer(*t.tokens, name);
	return ifx c then c.* else .{1, 0, 1, 1};
}

#scope_file

// Token values resolved from the official client's CSS (tools/probes/theme_tokens.js), in Theme_Name order.
// Read on the host: a cross-compile can't run the target's File module.
THEME_JSON := #run,host -> []string {
	#import "Basic";
	#import "File";
	out: [..]string;
	for string.["light", "ash", "dark", "onyx"] {
		s, ok := read_entire_file(tprint("%/../../assets/theme/%.json", #filepath, it));
		assert(ok, it);
		array_add(*out, s);
	}
	return out;
};

number :: (v: etf.Value, default: float64) -> float64 {
	if v.kind == .Float return v.f;
	if v.kind == .Int return cast(float64) v.i;
	return default;
}
