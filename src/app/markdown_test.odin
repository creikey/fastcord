package app

import "core:testing"

@(test)
test_md_inline :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	toks := md_inline("hi **bold _it_** `co*de*` <@123> <:pog:456> https://x.com/a. ~~s~~")
	kinds := make([dynamic]Token_Kind)
	for tk in toks do append(&kinds, tk.kind)
	testing.expect_value(t, toks[0].text, "hi ")
	testing.expect_value(t, toks[1].text, "bold ")
	testing.expect(t, toks[1].styles == {.Bold})
	testing.expect_value(t, toks[2].text, "it")
	testing.expect(t, toks[2].styles == {.Bold, .Italic})
	testing.expect_value(t, toks[4].text, "co*de*")
	testing.expect(t, toks[4].styles == {.Code})
	testing.expect_value(t, toks[6].kind, Token_Kind.User_Mention)
	testing.expect_value(t, toks[6].id, 123)
	testing.expect_value(t, toks[8].kind, Token_Kind.Custom_Emoji)
	testing.expect_value(t, toks[8].name, "pog")
	testing.expect_value(t, toks[10].kind, Token_Kind.Link)
	testing.expect_value(t, toks[10].text, "https://x.com/a")
	last := toks[len(toks) - 1]
	testing.expect_value(t, last.text, "s")
	testing.expect(t, last.styles == {.Strike})
	// unmatched delimiters stay literal; snake_case stays plain
	toks2 := md_inline("2 * 3 and snake_case_name")
	testing.expect_value(t, len(toks2), 1)
	testing.expect_value(t, toks2[0].text, "2 * 3 and snake_case_name")
	toks3 := md_inline("\\*not italic\\*")
	testing.expect_value(t, len(toks3), 1)
	testing.expect_value(t, toks3[0].text, "*not italic*")
}

@(test)
test_md_blocks :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	b := md_parse("# Title\nline one\nline two\n> quoted\n```odin\nx := 1\n```\n- item\n-# small")
	testing.expect_value(t, len(b), 6)
	testing.expect_value(t, b[0].kind, Block_Kind.Heading1)
	testing.expect_value(t, b[1].kind, Block_Kind.Paragraph)
	testing.expect_value(t, b[1].tokens[0].text, "line one\nline two")
	testing.expect_value(t, b[2].kind, Block_Kind.Quote)
	testing.expect_value(t, b[3].kind, Block_Kind.Code_Block)
	testing.expect_value(t, b[3].lang, "odin")
	testing.expect_value(t, b[3].code, "x := 1")
	testing.expect_value(t, b[4].kind, Block_Kind.List_Item)
	testing.expect_value(t, b[5].kind, Block_Kind.Subtext)
}
