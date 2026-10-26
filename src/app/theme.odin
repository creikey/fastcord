package app

import "core:encoding/json"
import "core:strings"
import "fc:ui"

Theme_Name :: enum u8 {
	Light,
	Ash,
	Dark,
	Onyx,
}

// Token values resolved from the official client's CSS (tools/probes/theme_tokens.js).
@(private = "file")
THEME_JSON := [Theme_Name][]byte {
	.Light = #load("../../assets/theme/light.json"),
	.Ash   = #load("../../assets/theme/ash.json"),
	.Dark  = #load("../../assets/theme/dark.json"),
	.Onyx  = #load("../../assets/theme/onyx.json"),
}

Theme :: struct {
	name:   Theme_Name,
	tokens: map[string]ui.Color,
}

theme_load :: proc(t: ^Theme, name: Theme_Name) {
	for k in t.tokens do delete(k)
	clear(&t.tokens)
	t.name = name
	v, err := json.parse(THEME_JSON[name], allocator = context.temp_allocator)
	if err != nil do return
	obj := v.(json.Object) or_else nil
	for k, val in obj {
		arr := val.(json.Array) or_else nil
		if len(arr) != 4 do continue
		c: ui.Color
		for i in 0 ..< 3 do c[i] = f32(arr[i].(json.Float) or_else f64(arr[i].(json.Integer) or_else 0)) / 255
		c[3] = f32(arr[3].(json.Float) or_else f64(arr[3].(json.Integer) or_else 1))
		t.tokens[strings.clone(k)] = c
	}
}

// Color for a CSS token like "--text-default". Missing tokens are magenta so they stand out.
tok :: proc(t: ^Theme, name: string) -> ui.Color {
	if c, ok := t.tokens[name]; ok do return c
	return {1, 0, 1, 1}
}
