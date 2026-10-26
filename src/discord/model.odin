// Package discord is an unofficial Discord user-client library whose network
// behaviour (requests, headers, gateway payloads, timing) is tested to match
// the official desktop client. This file holds the cached data model.
package discord

Snowflake :: distinct u64

DISCORD_EPOCH_MS :: 1420070400000

snowflake_time_ms :: proc(id: Snowflake) -> i64 {
	return i64(u64(id) >> 22) + DISCORD_EPOCH_MS
}

Channel_Type :: enum u8 {
	Guild_Text          = 0,
	DM                  = 1,
	Guild_Voice         = 2,
	Group_DM            = 3,
	Guild_Category      = 4,
	Guild_Announcement  = 5,
	Announcement_Thread = 10,
	Public_Thread       = 11,
	Private_Thread      = 12,
	Guild_Stage_Voice   = 13,
	Guild_Directory     = 14,
	Guild_Forum         = 15,
	Guild_Media         = 16,
}

Status :: enum u8 {
	Offline,
	Online,
	Idle,
	Dnd,
	Invisible,
}

status_from_string :: proc(s: string) -> Status {
	switch s {
	case "online":
		return .Online
	case "idle":
		return .Idle
	case "dnd":
		return .Dnd
	case "invisible":
		return .Invisible
	}
	return .Offline
}

status_name :: proc(s: Status) -> string {
	switch s {
	case .Online:
		return "online"
	case .Idle:
		return "idle"
	case .Dnd:
		return "dnd"
	case .Invisible:
		return "invisible"
	case .Offline:
		return "offline"
	}
	return "offline"
}

Relationship_Type :: enum u8 {
	None             = 0,
	Friend           = 1,
	Blocked          = 2,
	Incoming_Request = 3,
	Outgoing_Request = 4,
	Implicit         = 5,
}

User :: struct {
	id:            Snowflake,
	username:      string,
	global_name:   string,
	discriminator: string,
	avatar:        string, // hash, "" = default avatar
	banner:        string,
	accent_color:  Maybe(u32),
	bio:           string,
	pronouns:      string,
	bot:           bool,
	flags:         u64,
	premium_type:  int,
	// from GET /users/{id}/profile (with_mutual_guilds / with_mutual_friends)
	mutual_guilds:  int, // -1 until a profile with mutual guilds arrived
	mutual_friends: int, // -1 until known
}

display_name :: proc(u: ^User) -> string {
	return u.global_name != "" ? u.global_name : u.username
}

Role :: struct {
	id:            Snowflake,
	name:          string,
	color:         u32,
	position:      int,
	permissions:   u64,
	hoist:         bool,
	icon:          string,
	unicode_emoji: string,
}

Overwrite :: struct {
	id:    Snowflake,
	kind:  u8, // 0 role, 1 member
	allow: u64,
	deny:  u64,
}

Channel :: struct {
	id:                  Snowflake,
	kind:                Channel_Type,
	guild_id:            Snowflake,
	parent_id:           Snowflake,
	name:                string,
	topic:               string,
	position:            int,
	nsfw:                bool,
	last_message_id:     Snowflake,
	rate_limit_per_user: int,
	bitrate:             int,
	user_limit:          int,
	recipient_ids:       [dynamic]Snowflake, // DMs and group DMs
	icon:                string, // group DM icon
	owner_id:            Snowflake,
	overwrites:          [dynamic]Overwrite,
	flags:               u64,
}

Emoji :: struct {
	id:        Snowflake, // 0 for unicode emoji
	name:      string, // unicode emoji text or custom name
	animated:  bool,
	available: bool,
	guild_id:  Snowflake,
}

Sticker :: struct {
	id:          Snowflake,
	name:        string,
	format_type: int, // 1 png, 2 apng, 3 lottie, 4 gif
	guild_id:    Snowflake,
	description: string,
}

Guild :: struct {
	id:                Snowflake,
	name:              string,
	icon:              string,
	banner:            string,
	owner_id:          Snowflake,
	member_count:      int,
	channels:          [dynamic]Snowflake,
	roles:             [dynamic]Role,
	emojis:            [dynamic]Emoji,
	stickers:          [dynamic]Sticker,
	features:          [dynamic]string,
	system_channel_id: Snowflake,
	default_message_notifications: int, // 0 all messages, 1 only mentions
	unavailable:       bool,
	lazy:              bool,
	joined_at:         string,
}

Member :: struct {
	user_id:   Snowflake,
	nick:      string,
	avatar:    string,
	roles:     [dynamic]Snowflake,
	joined_at: string,
}

Attachment :: struct {
	id:            Snowflake,
	filename:      string,
	content_type:  string,
	size:          int,
	url:           string,
	proxy_url:     string,
	width:         int,
	height:        int,
	duration_secs: f32, // voice messages
	waveform:      string,
	flags:         u64,
}

Embed :: struct {
	kind:                     string,
	title:                    string,
	description:              string,
	url:                      string,
	color:                    u32,
	thumbnail_url:            string,
	thumbnail_w, thumbnail_h: int,
	image_url:                string,
	image_w, image_h:         int,
	video_url:                string,
	provider:                 string,
	author_name:              string,
}

Reaction :: struct {
	emoji:       Emoji,
	count:       int,
	burst_count: int,
	me:          bool,
	me_burst:    bool,
}

Message :: struct {
	id:               Snowflake,
	channel_id:       Snowflake,
	author_id:        Snowflake,
	kind:             int,
	content:          string,
	timestamp:        string,
	edited_timestamp: string,
	call_ended:       string, // CALL (type 3): call.ended_timestamp, "" while ongoing
	attachments:      [dynamic]Attachment,
	embeds:           [dynamic]Embed,
	reactions:        [dynamic]Reaction,
	sticker_ids:      [dynamic]Snowflake,
	mentions:         [dynamic]Snowflake,
	mention_everyone: bool,
	referenced_id:    Snowflake, // reply target
	flags:            u64,
	nonce:            string,
	pending:          bool, // sent by us, not yet acknowledged by the gateway
	failed:           bool,
}

Presence :: struct {
	user_id:  Snowflake,
	status:   Status,
	desktop:  Status,
	mobile:   Status,
	web:      Status,
	activity: string, // custom status text / "Playing X"
}

Read_State :: struct {
	channel_id:      Snowflake,
	last_message_id: Snowflake,
	mention_count:   int,
	last_viewed:     int, // days since the Discord epoch (ack body field)
	flags:           u64,
}

Voice_State :: struct {
	user_id:                                                    Snowflake,
	channel_id:                                                 Snowflake,
	guild_id:                                                   Snowflake,
	session_id:                                                 string,
	self_mute, self_deaf, mute, deaf, self_video, self_stream: bool,
}

Relationship :: struct {
	user_id:  Snowflake,
	kind:     Relationship_Type,
	nickname: string,
	since:    string,
}

Guild_Settings :: struct {
	guild_id:              Snowflake,
	muted:                 bool,
	message_notifications: int,
	suppress_everyone:     bool,
	suppress_roles:        bool,
	muted_channels:        [dynamic]Snowflake,
	collapsed_channels:    [dynamic]Snowflake,
}

Typing :: struct {
	user_id: Snowflake,
	until:   i64, // unix ms (start + 10 s)
}

Message_List :: struct {
	messages:        [dynamic]Message, // ascending by id
	loaded:          bool,
	loading:         bool,
	has_more_before: bool,
}

Member_List_Item :: struct {
	is_group: bool,
	group_id: string, // "online", "offline", or the role id in decimal (groups)
	role_id:  Snowflake, // non-zero for role (hoisted) groups
	count:    int, // group size (kept in sync with Member_List.groups)
	user_id:  Snowflake, // members
}

Member_List_Group :: struct {
	id:      string, // "online" / "offline" / role id in decimal
	role_id: Snowflake,
	count:   int,
}

Member_List :: struct {
	id:           string, // "everyone" or the channel permission hash
	member_count: int,
	online_count: int,
	groups:       [dynamic]Member_List_Group, // top-level "groups" of the latest update
	items:        [dynamic]Member_List_Item,
}

Theme :: enum u8 {
	Unset    = 0,
	Dark     = 1,
	Light    = 2,
	Darker   = 3,
	Midnight = 4,
}

Guild_Folder :: struct {
	id:        i64, // 0 = single-guild "folder"
	name:      string,
	color:     u64,
	has_color: bool,
	guild_ids: [dynamic]Snowflake,
}

User_Settings :: struct {
	theme:                Theme,
	status:               Status,
	custom_status_text:   string,
	custom_status_emoji:  string,
	locale:               string,
	timezone_offset:      int, // minutes
	developer_mode:       bool,
	guild_folders:        [dynamic]Guild_Folder,
	guild_positions:      [dynamic]Snowflake,
}

Session_Info :: struct {
	session_id: string,
	status:     Status,
	client:     string, // desktop / web / mobile
	os:         string,
}

Voice_Server :: struct {
	guild_id:   Snowflake,
	channel_id: Snowflake,
	token:      string,
	endpoint:   string,
	version:    u64, // bumped per VOICE_SERVER_UPDATE
}

Connection_State :: enum u8 {
	Disconnected,
	Connecting,
	Identifying,
	Resuming,
	Ready,
	Auth_Failed, // close 4004: token rejected
}
