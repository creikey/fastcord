package discord

import "core:testing"
import "fc:etf"

@(test)
invite_code_parsing :: proc(t: ^testing.T) {
	testing.expect_value(t, invite_code_from_input("hTKzmak"), "hTKzmak")
	testing.expect_value(t, invite_code_from_input("  https://discord.gg/cool-people  "), "cool-people")
	testing.expect_value(t, invite_code_from_input("discord.com/invite/abc_1?event=2"), "abc_1")
	testing.expect_value(t, invite_code_from_input("https://ptb.discord.com/invite/xyz/"), "xyz")
	testing.expect_value(t, invite_code_from_input("https://example.com/x!"), "")
	testing.expect_value(t, invite_code_from_input("not a code"), "")
}

@(test)
api_error_text_picks_field_error :: proc(t: ^testing.T) {
	v, err := etf.from_json(`{"code": 50035, "errors": {"username": {"_errors": [{"code": "USERNAME_ALREADY_TAKEN", "message": "Username is unavailable."}]}}, "message": "Invalid Form Body"}`, context.temp_allocator)
	testing.expect(t, err == .None)
	testing.expect_value(t, api_error_text(v), "Username is unavailable.")
	v2, _ := etf.from_json(`{"code": 50035, "message": "Password does not match."}`, context.temp_allocator)
	testing.expect_value(t, api_error_text(v2), "Password does not match.")
}

@(test)
account_info_from_ready_and_update :: proc(t: ^testing.T) {
	acc: Account_Info
	ready, _ := etf.from_json(`{"user": {"id": "42", "username": "a", "email": "a@b.co", "phone": null, "mfa_enabled": true}}`, context.temp_allocator)
	account_apply(&acc, 42, "READY", ready)
	testing.expect_value(t, acc.email, "a@b.co")
	testing.expect(t, acc.mfa_enabled && acc.phone == "")
	upd, _ := etf.from_json(`{"id": "42", "email": "new@b.co", "phone": "+15550001111"}`, context.temp_allocator)
	account_apply(&acc, 42, "USER_UPDATE", upd)
	testing.expect_value(t, acc.email, "new@b.co")
	testing.expect_value(t, acc.phone, "+15550001111")
	other, _ := etf.from_json(`{"id": "7", "email": "x@y.z"}`, context.temp_allocator)
	account_apply(&acc, 42, "USER_UPDATE", other)
	testing.expect_value(t, acc.email, "new@b.co")
}
