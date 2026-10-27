package discord

import "core:crypto/legacy/md5"
import "core:encoding/base64"
import "core:os"
import "core:strings"
import "core:testing"

@(test)
guild_admin_channel_names :: proc(t: ^testing.T) {
	testing.expect_value(t, channel_name_normalize("My New Channel", true), "my-new-channel")
	testing.expect_value(t, channel_name_normalize("  a  -- b ", true), "a-b-")
	testing.expect_value(t, channel_name_normalize("Hello!World?", true), "helloworld")
	testing.expect_value(t, channel_name_normalize("new ", true), "new-")
	testing.expect_value(t, channel_name_normalize("ünïcode ok", true), "ünïcode-ok")
	testing.expect_value(t, channel_name_normalize("  Voice Room  ", false), "Voice Room")
	testing.expect_value(t, len(channel_name_normalize(strings.repeat("a", 150, context.temp_allocator), true)), 100)
}

@(test)
guild_admin_emoji_names :: proc(t: ^testing.T) {
	testing.expect_value(t, emoji_name_from_filename("/Users/x/Pictures/fastcord_test.png"), "fastcord_test")
	testing.expect_value(t, emoji_name_from_filename(`C:\pics\party parrot.gif`), "party_parrot")
	testing.expect_value(t, emoji_name_from_filename("a.png"), "emoji")
	testing.expect_value(t, emoji_name_from_filename("x/.png"), "_png")
	testing.expect_value(t, len(emoji_name_from_filename(strings.repeat("b", 40, context.temp_allocator))), 32)
}

// The upload body matches the captured shape (traffic/upload_custom_emoji.jsonl):
// {"image":"data:image/png;base64,..","name":..} and the MD5 of the file.
@(test)
guild_admin_emoji_body :: proc(t: ^testing.T) {
	path := "src/imagefmt/testdata/t_trns_gray.png"
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return // run from another directory
	body, extra, status := file_job_body(path, "fastcord_test")
	testing.expect_value(t, status, 0)
	want := strings.concatenate({`{"image":"data:image/png;base64,`, base64.encode(data, allocator = context.temp_allocator), `","name":"fastcord_test"}`}, context.temp_allocator)
	testing.expect_value(t, body, want)
	ctx: md5.Context
	md5.init(&ctx)
	md5.update(&ctx, data)
	digest: [16]byte
	md5.final(&ctx, digest[:])
	testing.expect_value(t, len(extra), 1)
	testing.expect_value(t, extra[0].name, "x-discord-original-md5")
	testing.expect_value(t, len(extra[0].value), 32)
	hex := strings.builder_make(context.temp_allocator)
	for d in digest do strings.write_string(&hex, strings.to_lower(fmt_hex2(d), context.temp_allocator))
	testing.expect_value(t, extra[0].value, strings.to_string(hex))
	_, _, st2 := file_job_body("does/not/exist.png", "x")
	testing.expect_value(t, st2, -1)
	_, _, st3 := file_job_body("README.md", "x")
	testing.expect_value(t, st3, -1)
}

@(private = "file")
fmt_hex2 :: proc(b: byte) -> string {
	H := "0123456789ABCDEF"
	out := make([]byte, 2, context.temp_allocator)
	out[0], out[1] = H[b >> 4], H[b & 15]
	return string(out)
}

@(test)
guild_admin_error_message :: proc(t: ^testing.T) {
	v, _ := parse_json(transmute([]byte)string(`{"code":50035,"errors":{"name":{"_errors":[{"code":"BASE_TYPE_BAD_LENGTH","message":"Must be between 2 and 32 in length."}]}},"message":"Invalid Form Body"}`), context.temp_allocator)
	testing.expect_value(t, api_error_message(v), "Must be between 2 and 32 in length.")
	v2, _ := parse_json(transmute([]byte)string(`{"code":30008,"message":"Maximum number of emojis reached (50)"}`), context.temp_allocator)
	testing.expect_value(t, api_error_message(v2), "Maximum number of emojis reached (50)")
}

// Exact bodies (key order included) of the official client's event and channel writes.
@(test)
guild_admin_event_and_channel_bodies :: proc(t: ^testing.T) {
	// fixture start 2026-10-26T23:00:00.650Z: the next full hour, ms kept (UTC-7 local)
	now := i64(1793052587650) // 2026-10-26T22:09:47.650Z
	start := default_event_start_ms(now, -7 * 3_600_000)
	testing.expect_value(t, ms_to_iso(start), "2026-10-26T23:00:00.650Z")
	testing.expect_value(t, ms_to_iso(default_event_start_ms(now, 5 * 3_600_000 + 1_800_000)), "2026-10-26T22:30:00.650Z")
	voice := Event_Draft{name = "fastcord test event", start_ms = start, entity = .Voice, channel_id = 1564227670806364345}
	testing.expect_value(t, event_create_body(voice), `{"name":"fastcord test event","description":"","privacy_level":2,"scheduled_start_time":"2026-10-26T23:00:00.650Z","entity_type":2,"channel_id":"1564227670806364345","recurrence_rule":null}`)
	ext := Event_Draft{name = "picnic", start_ms = start, end_ms = start + 3_600_000, entity = .External, location = "the park"}
	testing.expect(t, strings.contains(event_create_body(ext), `"scheduled_end_time":"2026-10-27T00:00:00.650Z","entity_type":3,"entity_metadata":{"location":"the park"},"recurrence_rule":null}`))
	f := Channel_Form{name = "fc-temp", kind = .Guild_Text, topic = "fastcord temporary channel", bitrate = 64000}
	testing.expect_value(t, channel_edit_body(f), `{"name":"fc-temp","type":0,"topic":"fastcord temporary channel","bitrate":64000,"user_limit":0,"nsfw":false,"flags":0,"rate_limit_per_user":0}`)
}
