Snowflake :: u64;

DISCORD_EPOCH_MS :: 1420070400000;

snowflake_time_ms :: (id: Snowflake) -> s64 { return cast(s64) (id >> 22) + DISCORD_EPOCH_MS; }

Channel_Type :: enum u8 {
	Guild_Text :: 0;
	DM :: 1;
	Guild_Voice :: 2;
	Group_DM :: 3;
	Guild_Category :: 4;
	Guild_Announcement :: 5;
	Announcement_Thread :: 10;
	Public_Thread :: 11;
	Private_Thread :: 12;
	Guild_Stage_Voice :: 13;
	Guild_Directory :: 14;
	Guild_Forum :: 15;
	Guild_Media :: 16;
}

Status :: enum u8 {
	Offline;
	Online;
	Idle;
	Dnd;
	Invisible;
}

status_from_string :: (s: string) -> Status {
	if s == {
		case "online";    return .Online;
		case "idle";      return .Idle;
		case "dnd";       return .Dnd;
		case "invisible"; return .Invisible;
	}
	return .Offline;
}

status_name :: (s: Status) -> string {
	if s == {
		case .Online;    return "online";
		case .Idle;      return "idle";
		case .Dnd;       return "dnd";
		case .Invisible; return "invisible";
	}
	return "offline";
}

Relationship_Type :: enum u8 {
	None :: 0;
	Friend :: 1;
	Blocked :: 2;
	Incoming_Request :: 3;
	Outgoing_Request :: 4;
	Implicit :: 5;
}

User :: struct {
	id: Snowflake;
	username: string;
	global_name: string;
	discriminator: string;
	avatar: string; // hash, "" = default avatar
	banner: string;
	accent_color: u32;
	has_accent_color: bool; // the profile sets one (accent_color: null clears it)
	bio: string;
	pronouns: string;
	bot: bool;
	flags: u64;
	premium_type: int;
	// from GET /users/{id}/profile (with_mutual_guilds / with_mutual_friends)
	mutual_guilds: int; // -1 until a profile with mutual guilds arrived
	mutual_friends: int; // -1 until known
	// the last profile response, as user_profile_action reports it: ProfileProperty bits (user and
	// guild member) and the badge ids (a JSON array, "" = no profile yet)
	profile_props, guild_profile_props: u16;
	badges: string;
}

display_name :: (u: *User) -> string { return ifx u.global_name then u.global_name else u.username; }

Role :: struct {
	id: Snowflake;
	name: string;
	color: u32;
	position: int;
	permissions: u64;
	hoist: bool;
	mentionable: bool;
	icon: string;
	unicode_emoji: string;
	managed: bool; // a bot's or integration's: not editable
}

MAX_OVERWRITES :: 1000; // kept per channel (store.jai): far past any real channel's

Overwrite :: struct {
	id: Snowflake;
	kind: u8; // 0 role, 1 member
	allow: u64;
	deny: u64;
}

Channel :: struct {
	id: Snowflake;
	kind: Channel_Type;
	guild_id: Snowflake;
	parent_id: Snowflake;
	name: string;
	topic: string;
	position: int;
	nsfw: bool;
	last_message_id: Snowflake;
	rate_limit_per_user: int;
	bitrate: int;
	user_limit: int;
	rtc_region: string; // a voice channel's region override ("" = automatic)
	video_quality_mode: int; // 1 auto, 2 720p; 0 when Discord sent none
	recipient_ids: [..]Snowflake; // DMs and group DMs
	icon: string; // group DM icon
	owner_id: Snowflake;
	overwrites: [..]Overwrite;
	flags: u64;
	status: string; // a voice channel's status (CHANNEL_INFO, VOICE_CHANNEL_STATUS_UPDATE)
}

Emoji :: struct {
	id: Snowflake; // 0 for unicode emoji
	name: string; // unicode emoji text or custom name
	animated: bool;
	available: bool;
	guild_id: Snowflake;
}

Sticker :: struct {
	id: Snowflake;
	name: string;
	format_type: int; // 1 png, 2 apng, 3 lottie, 4 gif
	guild_id: Snowflake;
	description: string;
}

Guild :: struct {
	id: Snowflake;
	name: string;
	icon: string;
	banner: string;
	owner_id: Snowflake;
	member_count: int;
	premium_tier: int; // server boost level 0..3 (raises the upload limit)
	channels: [..]Snowflake;
	roles: [..]Role;
	emojis: [..]Emoji;
	stickers: [..]Sticker;
	features: [..]string;
	system_channel_id: Snowflake;
	default_message_notifications: int; // 0 all messages, 1 only mentions
	description: string;
	system_channel_flags: int;
	afk_channel_id: Snowflake;
	afk_timeout: int; // seconds
	verification_level: int;
	explicit_content_filter: int;
	mfa_level: int;
	vanity_url_code: string;
	rules_channel_id: Snowflake;
	public_updates_channel_id: Snowflake;
	safety_alerts_channel_id: Snowflake;
	preferred_locale: string;
	invites_disabled_until: string; // incidents_data: Pause Invites
	pending_owner_id: Snowflake; // hosted servers: offered to this member, waiting for them to accept
	unavailable: bool;
	lazy: bool;
	joined_at: string;
}

Member :: struct {
	user_id: Snowflake;
	nick: string;
	avatar: string;
	roles: [..]Snowflake;
	joined_at: string;
	flags: u64; // GuildMemberFlags: 1 DID_REJOIN
}

Attachment :: struct {
	id: Snowflake;
	filename: string;
	content_type: string;
	size: int;
	url: string;
	proxy_url: string;
	width: int;
	height: int;
	duration_secs: float32; // voice messages
	waveform: string;
	description: string; // alt text
	flags: u64;
}

Embed :: struct {
	kind: string;
	title: string;
	description: string;
	url: string;
	color: u32;
	thumbnail_url: string;
	thumbnail_w, thumbnail_h: int;
	image_url: string;
	image_w, image_h: int;
	video_url: string; // proxy_url when there is one, like the thumbnail and image
	video_w, video_h: int;
	provider: string;
	author_name: string;
	fields: []Embed_Field;
	footer: string;
	timestamp_ms: s64;
}

Embed_Field :: struct {
	name: string;
	value: string;
	is_inline: bool;
}

Reaction :: struct {
	emoji: Emoji;
	count: int;
	burst_count: int;
	me: bool;
	me_burst: bool;
	burst_color: u32; // 0xRRGGBB from burst_colors[0], 0 if none
}

Message :: struct {
	id: Snowflake;
	channel_id: Snowflake;
	author_id: Snowflake;
	kind: int;
	content: string;
	timestamp: string;
	edited_timestamp: string;
	call_ended: string; // CALL (type 3): call.ended_timestamp, "" while ongoing
	call_joined: bool; // CALL: we're among call.participants (an ended call we weren't in was missed)
	attachments: [..]Attachment;
	embeds: [..]Embed;
	reactions: [..]Reaction;
	sticker_ids: [..]Snowflake;
	mentions: [..]Snowflake;
	mention_everyone: bool;
	pinned: bool;
	referenced_id: Snowflake; // reply target
	// forwarded (message_reference type 1): the origin, and content etc. above come from the snapshot
	forwarded: bool;
	forward_channel_id: Snowflake;
	forward_message_id: Snowflake;
	forward_timestamp: string; // the original's timestamp
	flags: u64;
	nonce: string;
	webhook_name: string; // a webhook's name for this message alone ("" otherwise); each post may pick its own
	poll: *Poll; // store-owned, polls.jai; null for none
	pending: bool; // sent by us, not yet acknowledged by the gateway
	failed: bool;
}

Presence :: struct {
	user_id: Snowflake;
	status: Status;
	desktop: Status;
	mobile: Status;
	web: Status;
	activity: string; // custom status text / "Playing X"
	custom: string; // the custom status (type 4): its unicode emoji, a space, its text; "" for none
	activity_types: u32; // each activity's type + 1, a nibble each in order (user_profile_action)
}

Read_State :: struct {
	channel_id: Snowflake;
	last_message_id: Snowflake;
	mention_count: int;
	last_viewed: int; // days since the Discord epoch (ack body field)
	flags: u64;
	manual: bool; // set unread by Mark Unread (MESSAGE_ACK manual): not auto-acked until the channel is left
}

Voice_State :: struct {
	user_id: Snowflake;
	channel_id: Snowflake;
	guild_id: Snowflake;
	session_id: string;
	self_mute, self_deaf, mute, deaf, self_video, self_stream: bool;
	suppress: bool;          // a stage's audience (not a speaker)
	requested_to_speak: bool; // a stage's raised hand (request_to_speak_timestamp set), or an invitation to speak
}

Relationship :: struct {
	user_id: Snowflake;
	kind: Relationship_Type;
	ignored: bool;
	nickname: string;
	since: string;
}

Guild_Settings :: struct {
	guild_id: Snowflake;
	muted: bool;
	message_notifications: int;
	suppress_everyone: bool;
	suppress_roles: bool;
	muted_channels: [..]Snowflake;
	collapsed_channels: [..]Snowflake;
	mute_end_ms: s64; // mute_config.end_time (unix ms); 0 = until turned back on
	overrides: [..]Channel_Override; // channel_overrides (guild_settings.odin)
	flags: s64;
	mobile_push: bool;
	notify_highlights: int;
	mute_scheduled_events: bool;
	hide_muted_channels: bool; // the server's value (the app keeps its own local toggle)
}

Typing :: struct {
	user_id: Snowflake;
	until: s64; // unix ms (start + 10 s)
}

Message_List :: struct {
	messages: [..]Message; // ascending by id
	loaded: bool;
	loading: bool;
	failed: bool; // the last page request failed (LOAD_MESSAGES_FAILURE: "Messages Failed To Load")
	has_more_before: bool;
	stale: bool; // loaded before a fresh READY: the next first page replaces the messages
	// A jump landed on an older stretch: it ends at this id (the official hasMoreAfter). Newer stored
	// messages are the present side, not contiguous with it; messages_get leaves them out.
	gap_after: Snowflake;
}

Member_List_Item :: struct {
	is_group: bool;
	group_id: string; // "online", "offline", or the role id in decimal (groups)
	role_id: Snowflake; // non-zero for role (hoisted) groups
	count: int; // group size (kept in sync with Member_List.groups)
	user_id: Snowflake; // members
}

Member_List_Group :: struct {
	id: string; // "online" / "offline" / role id in decimal
	role_id: Snowflake;
	count: int;
}

Member_List :: struct {
	id: string; // "everyone" or the channel permission hash
	member_count: int;
	online_count: int;
	groups: [..]Member_List_Group; // top-level "groups" of the latest update
	items: [..]Member_List_Item;
}

Theme :: enum u8 {
	Unset :: 0;
	Dark :: 1;
	Light :: 2;
	Darker :: 3;
	Midnight :: 4;
}

Guild_Folder :: struct {
	id: s64; // 0 = single-guild "folder"
	name: string;
	color: u64;
	has_color: bool;
	guild_ids: [..]Snowflake;
}

User_Settings :: struct {
	theme: Theme;
	inbox_tab: Inbox_Tab; // InboxSettings.current_tab
	status: Status;
	custom_status_text: string;
	custom_status_emoji: string;
	custom_status_emoji_id: Snowflake;
	custom_status_expires_ms: s64;
	status_created_ms: s64; // StatusSettings.status_created_at_ms
	status_expires_ms: s64; // StatusSettings.status_expires_at_ms, 0 = forever
	locale: string;
	timezone_offset: int; // minutes
	developer_mode: bool;
	friend_online_off: bool; // NotificationSettings.notify_friends_on_launch = false
	// TextAndImages explicit (29) and gore (32) content settings for guilds, friend DMs and other
	// DMs (0 unset, 1 show, 2 blur, 3 block); unset ones default by nsfw_blocked (READY user's
	// nsfw_allowed == false)
	media_redaction: [2][3]u64;
	nsfw_blocked: bool;
	guild_folders: [..]Guild_Folder;
	guild_positions: [..]Snowflake;
}

Session_Info :: struct {
	session_id: string;
	status: Status;
	client: string; // desktop / web / mobile
	os: string;
}

// A Go Live stream we watch or broadcast: STREAM_CREATE / STREAM_SERVER_UPDATE,
// keyed "guild:<guild>:<channel>:<user>" or "call:<channel>:<user>".
Go_Live_Stream :: struct {
	key: string;
	rtc_server_id: Snowflake; // the stream's own voice server_id
	endpoint: string;
	token: string;
	paused: bool;
	version: u64; // bumped per STREAM_SERVER_UPDATE
}

Voice_Server :: struct {
	guild_id: Snowflake;
	channel_id: Snowflake;
	token: string;
	endpoint: string;
	version: u64; // bumped per VOICE_SERVER_UPDATE
}

Connection_State :: enum u8 {
	Disconnected;
	Connecting;
	Identifying;
	Resuming;
	Ready;
	Auth_Failed; // close 4004: token rejected
}
