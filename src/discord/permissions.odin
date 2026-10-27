package discord

// Permission computation, per Discord's documented algorithm
// (developers/topics/permissions "Permission Overwrites"):
//   base:    @everyone | each of the member's roles; owner or ADMINISTRATOR = all
//   channel: base, then @everyone overwrite, then the member's role overwrites
//            (allows and denies OR-ed together), then the member overwrite.
// Threads use their parent channel's overwrites. Without VIEW_CHANNEL a member
// implicitly has no permissions in the channel.

PERM_CREATE_INSTANT_INVITE :: u64(1) << 0
PERM_KICK_MEMBERS :: u64(1) << 1
PERM_BAN_MEMBERS :: u64(1) << 2
PERM_ADMINISTRATOR :: u64(1) << 3
PERM_MANAGE_CHANNELS :: u64(1) << 4
PERM_MANAGE_GUILD :: u64(1) << 5
PERM_ADD_REACTIONS :: u64(1) << 6
PERM_VIEW_CHANNEL :: u64(1) << 10
PERM_SEND_MESSAGES :: u64(1) << 11
PERM_MANAGE_MESSAGES :: u64(1) << 13
PERM_ATTACH_FILES :: u64(1) << 15
PERM_MENTION_EVERYONE :: u64(1) << 17
PERM_CONNECT :: u64(1) << 20
PERM_CHANGE_NICKNAME :: u64(1) << 26
PERM_MANAGE_NICKNAMES :: u64(1) << 27
PERM_SPEAK :: u64(1) << 21
PERM_MANAGE_ROLES :: u64(1) << 28
PERM_MANAGE_GUILD_EXPRESSIONS :: u64(1) << 30
PERM_MANAGE_EVENTS :: u64(1) << 33
PERM_MANAGE_THREADS :: u64(1) << 34
PERM_CREATE_PUBLIC_THREADS :: u64(1) << 35
PERM_CREATE_GUILD_EXPRESSIONS :: u64(1) << 43
PERM_CREATE_EVENTS :: u64(1) << 44

PERM_ALL :: max(u64)

// compute_base_permissions: guild-level permissions of user_id holding member_roles.
compute_base_permissions :: proc(g: ^Guild, user_id: Snowflake, member_roles: []Snowflake) -> u64 {
	if g == nil do return 0
	if g.owner_id != 0 && g.owner_id == user_id do return PERM_ALL
	perms: u64
	for r in g.roles {
		if r.id == g.id {
			perms |= r.permissions // @everyone shares the guild's id
			continue
		}
		for rid in member_roles {
			if rid == r.id {
				perms |= r.permissions
				break
			}
		}
	}
	if perms & PERM_ADMINISTRATOR != 0 do return PERM_ALL
	return perms
}

// compute_overwrites applies a channel's overwrites to base permissions.
compute_overwrites :: proc(base: u64, guild_id, user_id: Snowflake, member_roles: []Snowflake, overwrites: []Overwrite) -> u64 {
	if base & PERM_ADMINISTRATOR != 0 do return PERM_ALL
	perms := base
	for o in overwrites {
		if o.kind == 0 && o.id == guild_id {
			perms &~= o.deny
			perms |= o.allow
			break
		}
	}
	allow, deny: u64
	for o in overwrites {
		if o.kind != 0 || o.id == guild_id do continue
		for rid in member_roles {
			if rid == o.id {
				allow |= o.allow
				deny |= o.deny
				break
			}
		}
	}
	perms &~= deny
	perms |= allow
	for o in overwrites {
		if o.kind == 1 && o.id == user_id {
			perms &~= o.deny
			perms |= o.allow
			break
		}
	}
	if perms & PERM_VIEW_CHANNEL == 0 do return 0
	return perms
}

// Our role ids in a guild: the READY / member-update side table, else the Store's member.
my_roles :: proc(s: ^Store, guild_id: Snowflake) -> []Snowflake {
	if r := my_guild_roles(guild_id); r != nil do return r
	if m := member_get(s, guild_id, s.me); m != nil do return m.roles[:]
	return nil
}

// guild_permissions: our guild-level permissions.
guild_permissions :: proc(s: ^Store, guild_id: Snowflake) -> u64 {
	return compute_base_permissions(guild_get(s, guild_id), s.me, my_roles(s, guild_id))
}

// channel_permissions: our permissions in a guild channel (threads: their parent's).
// DMs and unknown channels give 0.
channel_permissions :: proc(s: ^Store, channel_id: Snowflake) -> u64 {
	ch := channel_get(s, channel_id)
	if ch == nil || ch.guild_id == 0 do return 0
	return channel_permissions_of(s, channel_id, s.me, my_roles(s, ch.guild_id))
}

// channel_permissions_of: user_id's permissions in a channel, given their role ids.
channel_permissions_of :: proc(s: ^Store, channel_id, user_id: Snowflake, roles: []Snowflake) -> u64 {
	ch := channel_get(s, channel_id)
	if ch == nil || ch.guild_id == 0 do return 0
	if is_thread(ch) && ch.parent_id != 0 {
		if p := channel_get(s, ch.parent_id); p != nil do ch = p
	}
	g := guild_get(s, ch.guild_id)
	if g == nil do return 0
	base := compute_base_permissions(g, user_id, roles)
	return compute_overwrites(base, g.id, user_id, roles, ch.overwrites[:])
}

// can_set_nickname: may we change user_id's server nickname? Our own needs
// CHANGE_NICKNAME (or MANAGE_NICKNAMES); someone else's needs MANAGE_NICKNAMES and,
// unless we own the guild, a highest role above theirs (the owner's can't be changed).
can_set_nickname :: proc(s: ^Store, guild_id, user_id: Snowflake) -> bool {
	g := guild_get(s, guild_id)
	if g == nil do return false
	perms := guild_permissions(s, guild_id)
	if user_id == s.me do return has_permission(perms, PERM_CHANGE_NICKNAME) || has_permission(perms, PERM_MANAGE_NICKNAMES)
	if !has_permission(perms, PERM_MANAGE_NICKNAMES) do return false
	if g.owner_id == s.me do return true
	if g.owner_id == user_id do return false
	highest :: proc(g: ^Guild, roles: []Snowflake) -> int {
		top := 0
		for r in g.roles do for rid in roles do if rid == r.id && r.position > top do top = r.position
		return top
	}
	theirs: []Snowflake
	if m := member_get(s, guild_id, user_id); m != nil do theirs = m.roles[:]
	return highest(g, my_roles(s, guild_id)) > highest(g, theirs)
}

// has_permission: every bit of `want` is set.
has_permission :: proc(perms, want: u64) -> bool {return perms & want == want}
