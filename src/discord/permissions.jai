// Permission computation, per Discord's documented algorithm
// (developers/topics/permissions "Permission Overwrites"):
//   base:    @everyone | each of the member's roles; owner or ADMINISTRATOR = all
//   channel: base, then @everyone overwrite, then the member's role overwrites
//            (allows and denies OR-ed together), then the member overwrite.
// Threads use their parent channel's overwrites. Without VIEW_CHANNEL a member
// implicitly has no permissions in the channel.

PERM_CREATE_INSTANT_INVITE :: (cast(u64) 1) << 0;
PERM_KICK_MEMBERS :: (cast(u64) 1) << 1;
PERM_BAN_MEMBERS :: (cast(u64) 1) << 2;
PERM_ADMINISTRATOR :: (cast(u64) 1) << 3;
PERM_MANAGE_CHANNELS :: (cast(u64) 1) << 4;
PERM_MANAGE_GUILD :: (cast(u64) 1) << 5;
PERM_ADD_REACTIONS :: (cast(u64) 1) << 6;
PERM_VIEW_CHANNEL :: (cast(u64) 1) << 10;
PERM_SEND_MESSAGES :: (cast(u64) 1) << 11;
PERM_MANAGE_MESSAGES :: (cast(u64) 1) << 13;
PERM_ATTACH_FILES :: (cast(u64) 1) << 15;
PERM_MENTION_EVERYONE :: (cast(u64) 1) << 17;
PERM_CONNECT :: (cast(u64) 1) << 20;
PERM_CHANGE_NICKNAME :: (cast(u64) 1) << 26;
PERM_MANAGE_NICKNAMES :: (cast(u64) 1) << 27;
PERM_SPEAK :: (cast(u64) 1) << 21;
PERM_MANAGE_ROLES :: (cast(u64) 1) << 28;
PERM_MANAGE_GUILD_EXPRESSIONS :: (cast(u64) 1) << 30;
PERM_MANAGE_EVENTS :: (cast(u64) 1) << 33;
PERM_MANAGE_THREADS :: (cast(u64) 1) << 34;
PERM_CREATE_PUBLIC_THREADS :: (cast(u64) 1) << 35;
PERM_CREATE_GUILD_EXPRESSIONS :: (cast(u64) 1) << 43;
PERM_CREATE_EVENTS :: (cast(u64) 1) << 44;

PERM_ALL :: U64_MAX;

// compute_base_permissions: guild-level permissions of user_id holding member_roles.
compute_base_permissions :: (g: *Guild, user_id: Snowflake, member_roles: []Snowflake) -> u64 {
	if !g return 0;
	if g.owner_id != 0 && g.owner_id == user_id return PERM_ALL;
	perms: u64;
	for r: g.roles {
		if r.id == g.id {
			perms |= r.permissions; // @everyone shares the guild's id
			continue;
		}
		if array_find(member_roles, r.id) perms |= r.permissions;
	}
	return ifx (perms & PERM_ADMINISTRATOR) then PERM_ALL else perms;
}

// compute_overwrites applies a channel's overwrites to base permissions.
compute_overwrites :: (base: u64, guild_id: Snowflake, user_id: Snowflake, member_roles: []Snowflake, overwrites: []Overwrite) -> u64 {
	if base & PERM_ADMINISTRATOR return PERM_ALL;
	perms := base;
	for o: overwrites {
		if o.kind == 0 && o.id == guild_id {
			perms = (perms & ~o.deny) | o.allow;
			break;
		}
	}
	allow, deny: u64;
	for o: overwrites {
		if o.kind == 0 && o.id != guild_id && array_find(member_roles, o.id) {
			allow |= o.allow;
			deny |= o.deny;
		}
	}
	perms &= ~deny;
	perms |= allow;
	for o: overwrites {
		if o.kind == 1 && o.id == user_id {
			perms = (perms & ~o.deny) | o.allow;
			break;
		}
	}
	return ifx (perms & PERM_VIEW_CHANNEL) then perms else 0;
}

// Our role ids in a guild: the READY / member-update side table, else the Store's member.
my_roles :: (s: *Store, guild_id: Snowflake) -> []Snowflake {
	r := my_guild_roles(guild_id);
	if r.data return r; // the side table knows (even "no roles")
	m := member_get(s, guild_id, s.me);
	if m return m.roles;
	return .[];
}

// guild_permissions: our guild-level permissions.
guild_permissions :: (s: *Store, guild_id: Snowflake) -> u64 {
	return compute_base_permissions(guild_get(s, guild_id), s.me, my_roles(s, guild_id));
}

// channel_permissions: our permissions in a guild channel (threads: their parent's).
// DMs and unknown channels give 0.
channel_permissions :: (s: *Store, channel_id: Snowflake) -> u64 {
	ch := channel_get(s, channel_id);
	if !ch || ch.guild_id == 0 return 0;
	return channel_permissions_of(s, channel_id, s.me, my_roles(s, ch.guild_id));
}

// channel_permissions_of: user_id's permissions in a channel, given their role ids.
channel_permissions_of :: (s: *Store, channel_id: Snowflake, user_id: Snowflake, roles: []Snowflake) -> u64 {
	ch := channel_get(s, channel_id);
	if !ch || ch.guild_id == 0 return 0;
	if is_thread(ch) && ch.parent_id {
		p := channel_get(s, ch.parent_id);
		if p ch = p;
	}
	g := guild_get(s, ch.guild_id);
	if !g return 0;
	return compute_overwrites(compute_base_permissions(g, user_id, roles), g.id, user_id, roles, ch.overwrites);
}

// can_set_nickname: may we change user_id's server nickname? Our own needs
// CHANGE_NICKNAME (or MANAGE_NICKNAMES); someone else's needs MANAGE_NICKNAMES and,
// unless we own the guild, a highest role above theirs (the owner's can't be changed).
can_set_nickname :: (s: *Store, guild_id: Snowflake, user_id: Snowflake) -> bool {
	g := guild_get(s, guild_id);
	if !g return false;
	perms := guild_permissions(s, guild_id);
	if user_id == s.me return has_permission(perms, PERM_CHANGE_NICKNAME) || has_permission(perms, PERM_MANAGE_NICKNAMES);
	if !has_permission(perms, PERM_MANAGE_NICKNAMES) return false;
	if g.owner_id == s.me return true;
	if g.owner_id == user_id return false;
	highest :: (g: *Guild, roles: []Snowflake) -> int {
		top := 0;
		for g.roles if it.position > top && array_find(roles, it.id) top = it.position;
		return top;
	}
	m := member_get(s, guild_id, user_id);
	theirs: []Snowflake;
	if m theirs = m.roles;
	return highest(g, my_roles(s, guild_id)) > highest(g, theirs);
}

// has_permission: every bit of `want` is set.
has_permission :: (perms: u64, want: u64) -> bool { return (perms & want) == want; }

