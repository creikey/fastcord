package app

import "core:testing"

@(test)
test_emoji_segmentation :: proc(t: ^testing.T) {
	segs :: proc(s: string) -> []string {
		out := make([dynamic]string, context.temp_allocator)
		pos := 0
		for {
			seg, ok := emoji_next(s, pos)
			if !ok do break
			append(&out, s[seg.start:seg.end])
			pos = seg.end
		}
		return out[:]
	}
	family :: "👨‍👩‍👧‍👦"
	got := segs("a 😀b 👍🏽 " + family + " 🇯🇵🇺🇸 1️⃣ ❤️ ❤ 12 ™ © x")
	want := []string{"😀", "👍🏽", family, "🇯🇵", "🇺🇸", "1️⃣", "❤️", "❤"}
	testing.expectf(t, len(got) == len(want), "got %v", got)
	for w, i in want do if i < len(got) do testing.expect_value(t, got[i], w)

	n, only := emoji_count(" 😂🎉 👀 ")
	testing.expect(t, n == 3 && only)
	_, only2 := emoji_count("😂 hi")
	testing.expect(t, !only2)

	testing.expect(t, emoji_lookup_name(":thumbsup:") == emoji_lookup_surrogates("👍"))
	testing.expect(t, emoji_lookup_surrogates("❤") == emoji_lookup_surrogates("❤️"))
	testing.expect_value(t, emoji_convert_shortcodes("hi :thumbsup: :nope: `:smile:` :+1:"), "hi 👍 :nope: `:smile:` 👍")
}
