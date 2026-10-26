package vector

// Generated list of Chrome reference renders (tools/probes/chrome_icon_fixtures.py):
// alpha of the official client's Chrome drawing each SVG via drawImage: directly at
// 48px, and at 384px box-filtered to 48 / 24 px (exact-area reference).

@(private)
Chrome_Fixture :: struct {
	name:     string,
	svg:      string,
	a48:      []u8, // direct 48px (Skia AA)
	ss48:     []u8, // 8x8 supersampled to 48px
	ss24:     []u8, // 16x16 supersampled to 24px
}

@(private)
CHROME_FIXTURES := [?]Chrome_Fixture {
	{"friends", #load("../../assets/icons/friends.svg", string), #load("testdata/chrome/friends_48.a8"), #load("testdata/chrome/friends_ss48.a8"), #load("testdata/chrome/friends_ss24.a8")},
	{"compass", #load("../../assets/icons/compass.svg", string), #load("testdata/chrome/compass_48.a8"), #load("testdata/chrome/compass_ss48.a8"), #load("testdata/chrome/compass_ss24.a8")},
	{"settings", #load("../../assets/icons/settings.svg", string), #load("testdata/chrome/settings_48.a8"), #load("testdata/chrome/settings_ss48.a8"), #load("testdata/chrome/settings_ss24.a8")},
	{"microphone-slash", #load("../../assets/icons/microphone-slash.svg", string), #load("testdata/chrome/microphone-slash_48.a8"), #load("testdata/chrome/microphone-slash_ss48.a8"), #load("testdata/chrome/microphone-slash_ss24.a8")},
	{"headphones-slash", #load("../../assets/icons/headphones-slash.svg", string), #load("testdata/chrome/headphones-slash_48.a8"), #load("testdata/chrome/headphones-slash_ss48.a8"), #load("testdata/chrome/headphones-slash_ss24.a8")},
	{"hashmark", #load("../../assets/icons/hashmark.svg", string), #load("testdata/chrome/hashmark_48.a8"), #load("testdata/chrome/hashmark_ss48.a8"), #load("testdata/chrome/hashmark_ss24.a8")},
	{"text", #load("../../assets/icons/text.svg", string), #load("testdata/chrome/text_48.a8"), #load("testdata/chrome/text_ss48.a8"), #load("testdata/chrome/text_ss24.a8")},
	{"voice-normal", #load("../../assets/icons/voice-normal.svg", string), #load("testdata/chrome/voice-normal_48.a8"), #load("testdata/chrome/voice-normal_ss48.a8"), #load("testdata/chrome/voice-normal_ss24.a8")},
	{"announcements", #load("../../assets/icons/announcements.svg", string), #load("testdata/chrome/announcements_48.a8"), #load("testdata/chrome/announcements_ss48.a8"), #load("testdata/chrome/announcements_ss24.a8")},
	{"thread", #load("../../assets/icons/thread.svg", string), #load("testdata/chrome/thread_48.a8"), #load("testdata/chrome/thread_ss48.a8"), #load("testdata/chrome/thread_ss24.a8")},
	{"forum", #load("../../assets/icons/forum.svg", string), #load("testdata/chrome/forum_48.a8"), #load("testdata/chrome/forum_ss48.a8"), #load("testdata/chrome/forum_ss24.a8")},
	{"at", #load("../../assets/icons/at.svg", string), #load("testdata/chrome/at_48.a8"), #load("testdata/chrome/at_ss48.a8"), #load("testdata/chrome/at_ss24.a8")},
	{"gif", #load("../../assets/icons/gif.svg", string), #load("testdata/chrome/gif_48.a8"), #load("testdata/chrome/gif_ss48.a8"), #load("testdata/chrome/gif_ss24.a8")},
	{"sticker", #load("../../assets/icons/sticker.svg", string), #load("testdata/chrome/sticker_48.a8"), #load("testdata/chrome/sticker_ss48.a8"), #load("testdata/chrome/sticker_ss24.a8")},
	{"gift", #load("../../assets/icons/gift.svg", string), #load("testdata/chrome/gift_48.a8"), #load("testdata/chrome/gift_ss48.a8"), #load("testdata/chrome/gift_ss24.a8")},
	{"circle-plus", #load("../../assets/icons/circle-plus.svg", string), #load("testdata/chrome/circle-plus_48.a8"), #load("testdata/chrome/circle-plus_ss48.a8"), #load("testdata/chrome/circle-plus_ss24.a8")},
	{"magnifying-glass", #load("../../assets/icons/magnifying-glass.svg", string), #load("testdata/chrome/magnifying-glass_48.a8"), #load("testdata/chrome/magnifying-glass_ss48.a8"), #load("testdata/chrome/magnifying-glass_ss24.a8")},
	{"pin", #load("../../assets/icons/pin.svg", string), #load("testdata/chrome/pin_48.a8"), #load("testdata/chrome/pin_ss48.a8"), #load("testdata/chrome/pin_ss24.a8")},
	{"inbox", #load("../../assets/icons/inbox.svg", string), #load("testdata/chrome/inbox_48.a8"), #load("testdata/chrome/inbox_ss48.a8"), #load("testdata/chrome/inbox_ss24.a8")},
	{"clyde", #load("../../assets/icons/clyde.svg", string), #load("testdata/chrome/clyde_48.a8"), #load("testdata/chrome/clyde_ss48.a8"), #load("testdata/chrome/clyde_ss24.a8")},
	{"nitro-wheel", #load("../../assets/icons/nitro-wheel.svg", string), #load("testdata/chrome/nitro-wheel_48.a8"), #load("testdata/chrome/nitro-wheel_ss48.a8"), #load("testdata/chrome/nitro-wheel_ss24.a8")},
	{"status-idle", #load("../../assets/icons/status-idle.svg", string), #load("testdata/chrome/status-idle_48.a8"), #load("testdata/chrome/status-idle_ss48.a8"), #load("testdata/chrome/status-idle_ss24.a8")},
	{"status-dnd", #load("../../assets/icons/status-dnd.svg", string), #load("testdata/chrome/status-dnd_48.a8"), #load("testdata/chrome/status-dnd_ss48.a8"), #load("testdata/chrome/status-dnd_ss24.a8")},
	{"status-online-mobile", #load("../../assets/icons/status-online-mobile.svg", string), #load("testdata/chrome/status-online-mobile_48.a8"), #load("testdata/chrome/status-online-mobile_ss48.a8"), #load("testdata/chrome/status-online-mobile_ss24.a8")},
	{"status-online-vr", #load("../../assets/icons/status-online-vr.svg", string), #load("testdata/chrome/status-online-vr_48.a8"), #load("testdata/chrome/status-online-vr_ss48.a8"), #load("testdata/chrome/status-online-vr_ss24.a8")},
	{"mask-avatar-status-round-32", #load("../../assets/icons/mask-avatar-status-round-32.svg", string), #load("testdata/chrome/mask-avatar-status-round-32_48.a8"), #load("testdata/chrome/mask-avatar-status-round-32_ss48.a8"), #load("testdata/chrome/mask-avatar-status-round-32_ss24.a8")},
	{"typing-dots", #load("../../assets/icons/typing-dots.svg", string), #load("testdata/chrome/typing-dots_48.a8"), #load("testdata/chrome/typing-dots_ss48.a8"), #load("testdata/chrome/typing-dots_ss24.a8")},
	{"x-large", #load("../../assets/icons/x-large.svg", string), #load("testdata/chrome/x-large_48.a8"), #load("testdata/chrome/x-large_ss48.a8"), #load("testdata/chrome/x-large_ss24.a8")},
	{"chevron-small-down", #load("../../assets/icons/chevron-small-down.svg", string), #load("testdata/chrome/chevron-small-down_48.a8"), #load("testdata/chrome/chevron-small-down_ss48.a8"), #load("testdata/chrome/chevron-small-down_ss24.a8")},
	{"more-horizontal", #load("../../assets/icons/more-horizontal.svg", string), #load("testdata/chrome/more-horizontal_48.a8"), #load("testdata/chrome/more-horizontal_ss48.a8"), #load("testdata/chrome/more-horizontal_ss24.a8")},
	{"reaction", #load("../../assets/icons/reaction.svg", string), #load("testdata/chrome/reaction_48.a8"), #load("testdata/chrome/reaction_ss48.a8"), #load("testdata/chrome/reaction_ss24.a8")},
	{"arrow-angle-left-up", #load("../../assets/icons/arrow-angle-left-up.svg", string), #load("testdata/chrome/arrow-angle-left-up_48.a8"), #load("testdata/chrome/arrow-angle-left-up_ss48.a8"), #load("testdata/chrome/arrow-angle-left-up_ss24.a8")},
	{"pencil", #load("../../assets/icons/pencil.svg", string), #load("testdata/chrome/pencil_48.a8"), #load("testdata/chrome/pencil_ss48.a8"), #load("testdata/chrome/pencil_ss24.a8")},
	{"circle-x", #load("../../assets/icons/circle-x.svg", string), #load("testdata/chrome/circle-x_48.a8"), #load("testdata/chrome/circle-x_ss48.a8"), #load("testdata/chrome/circle-x_ss24.a8")},
	{"emoji-grinning-face", #load("../../assets/icons/emoji-grinning-face.svg", string), #load("testdata/chrome/emoji-grinning-face_48.a8"), #load("testdata/chrome/emoji-grinning-face_ss48.a8"), #load("testdata/chrome/emoji-grinning-face_ss24.a8")},
	{"shop", #load("../../assets/icons/shop.svg", string), #load("testdata/chrome/shop_48.a8"), #load("testdata/chrome/shop_ss48.a8"), #load("testdata/chrome/shop_ss24.a8")},
	{"quests", #load("../../assets/icons/quests.svg", string), #load("testdata/chrome/quests_48.a8"), #load("testdata/chrome/quests_ss48.a8"), #load("testdata/chrome/quests_ss24.a8")},
	{"plus-large", #load("../../assets/icons/plus-large.svg", string), #load("testdata/chrome/plus-large_48.a8"), #load("testdata/chrome/plus-large_ss48.a8"), #load("testdata/chrome/plus-large_ss24.a8")},
	{"user-plus", #load("../../assets/icons/user-plus.svg", string), #load("testdata/chrome/user-plus_48.a8"), #load("testdata/chrome/user-plus_ss48.a8"), #load("testdata/chrome/user-plus_ss24.a8")},
	{"guild-blob", #load("../../assets/icons/guild-blob.svg", string), #load("testdata/chrome/guild-blob_48.a8"), #load("testdata/chrome/guild-blob_ss48.a8"), #load("testdata/chrome/guild-blob_ss24.a8")},
	{"stroke_shapes", #load("testdata/stroke_shapes.svg", string), #load("testdata/chrome/stroke_shapes_48.a8"), #load("testdata/chrome/stroke_shapes_ss48.a8"), #load("testdata/chrome/stroke_shapes_ss24.a8")},
	{"misc_shapes", #load("testdata/misc_shapes.svg", string), #load("testdata/chrome/misc_shapes_48.a8"), #load("testdata/chrome/misc_shapes_ss48.a8"), #load("testdata/chrome/misc_shapes_ss24.a8")},
}
