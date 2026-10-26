package app

import "core:testing"

@(test)
test_clean_token :: proc(t: ^testing.T) {
	testing.expect_value(t, clean_token("  abc.def.ghi \n"), "abc.def.ghi")
	testing.expect_value(t, clean_token("\"abc.def.ghi\""), "abc.def.ghi")
	testing.expect_value(t, clean_token("authorization: abc.def.ghi"), "abc.def.ghi")
	testing.expect_value(t, clean_token("\"Authorization: 'abc.def.ghi'\""), "abc.def.ghi")
	testing.expect_value(t, clean_token("   "), "")
}
