package discord

import "core:testing"

@(private = "file")
perm_guild :: proc(owner: Snowflake) -> Guild {
	g := Guild{id = 100, owner_id = owner}
	g.roles = make([dynamic]Role, context.temp_allocator)
	append(&g.roles, Role{id = 100, permissions = PERM_VIEW_CHANNEL | PERM_SEND_MESSAGES}) // @everyone
	append(&g.roles, Role{id = 201, permissions = PERM_MANAGE_CHANNELS})
	append(&g.roles, Role{id = 202, permissions = PERM_ADMINISTRATOR})
	append(&g.roles, Role{id = 203, permissions = PERM_MANAGE_GUILD_EXPRESSIONS})
	return g
}

@(test)
permissions_base :: proc(t: ^testing.T) {
	g := perm_guild(1)
	// owner: everything, with no roles at all
	testing.expect_value(t, compute_base_permissions(&g, 1, nil), PERM_ALL)
	// @everyone only
	testing.expect_value(t, compute_base_permissions(&g, 2, nil), PERM_VIEW_CHANNEL | PERM_SEND_MESSAGES)
	// roles OR together; roles the guild doesn't have are ignored
	testing.expect_value(t, compute_base_permissions(&g, 2, {201, 203, 999}), PERM_VIEW_CHANNEL | PERM_SEND_MESSAGES | PERM_MANAGE_CHANNELS | PERM_MANAGE_GUILD_EXPRESSIONS)
	// administrator: everything
	testing.expect_value(t, compute_base_permissions(&g, 2, {202}), PERM_ALL)
	testing.expect_value(t, compute_base_permissions(nil, 2, nil), u64(0))
}

@(test)
permissions_overwrites :: proc(t: ^testing.T) {
	base := PERM_VIEW_CHANNEL | PERM_SEND_MESSAGES | PERM_MANAGE_CHANNELS
	// @everyone deny send, role 201 allows it back, member denies manage channels
	ows := []Overwrite {
		{id = 100, kind = 0, deny = PERM_SEND_MESSAGES},
		{id = 201, kind = 0, allow = PERM_SEND_MESSAGES | PERM_ATTACH_FILES},
		{id = 2, kind = 1, deny = PERM_MANAGE_CHANNELS},
		{id = 3, kind = 1, allow = PERM_MANAGE_CHANNELS},
	}
	testing.expect_value(t, compute_overwrites(base, 100, 2, {201}, ows), PERM_VIEW_CHANNEL | PERM_SEND_MESSAGES | PERM_ATTACH_FILES)
	// no role: the @everyone deny stands; another member's overwrite doesn't apply
	testing.expect_value(t, compute_overwrites(base, 100, 5, nil, ows), PERM_VIEW_CHANNEL | PERM_MANAGE_CHANNELS)
	// role allows and denies combine before applying: a deny from one role and an allow
	// from another -> allowed (allow is applied after deny)
	ows2 := []Overwrite{{id = 201, kind = 0, deny = PERM_SEND_MESSAGES}, {id = 203, kind = 0, allow = PERM_SEND_MESSAGES}}
	testing.expect_value(t, compute_overwrites(PERM_VIEW_CHANNEL, 100, 5, {201, 203}, ows2), PERM_VIEW_CHANNEL | PERM_SEND_MESSAGES)
	// member overwrite beats role overwrites
	ows3 := []Overwrite{{id = 201, kind = 0, allow = PERM_SEND_MESSAGES}, {id = 5, kind = 1, deny = PERM_SEND_MESSAGES}}
	testing.expect_value(t, compute_overwrites(PERM_VIEW_CHANNEL, 100, 5, {201}, ows3), PERM_VIEW_CHANNEL)
	// losing VIEW_CHANNEL drops everything
	ows4 := []Overwrite{{id = 100, kind = 0, deny = PERM_VIEW_CHANNEL}}
	testing.expect_value(t, compute_overwrites(base, 100, 5, nil, ows4), u64(0))
	// a member overwrite can grant VIEW_CHANNEL back
	ows5 := []Overwrite{{id = 100, kind = 0, deny = PERM_VIEW_CHANNEL}, {id = 5, kind = 1, allow = PERM_VIEW_CHANNEL}}
	testing.expect_value(t, compute_overwrites(base, 100, 5, nil, ows5), base)
	// administrators ignore overwrites
	testing.expect_value(t, compute_overwrites(PERM_ALL, 100, 5, nil, ows4), PERM_ALL)
}

@(test)
permissions_store :: proc(t: ^testing.T) {
	s: Store
	store_init(&s, context.temp_allocator)
	g := perm_guild(1)
	s.guilds[100] = g
	ch := Channel{id = 300, guild_id = 100, kind = .Guild_Text, overwrites = make([dynamic]Overwrite, context.temp_allocator)}
	append(&ch.overwrites, Overwrite{id = 201, kind = 0, deny = PERM_MANAGE_CHANNELS})
	s.channels[300] = ch
	s.channels[301] = Channel{id = 301, guild_id = 100, kind = .Public_Thread, parent_id = 300}
	s.channels[302] = Channel{id = 302, kind = .DM}
	roles := []Snowflake{201}
	testing.expect_value(t, compute_base_permissions(&s.guilds[100], 7, roles), PERM_VIEW_CHANNEL | PERM_SEND_MESSAGES | PERM_MANAGE_CHANNELS)
	testing.expect_value(t, channel_permissions_of(&s, 300, 7, roles), PERM_VIEW_CHANNEL | PERM_SEND_MESSAGES)
	// threads take their parent's overwrites
	testing.expect_value(t, channel_permissions_of(&s, 301, 7, roles), PERM_VIEW_CHANNEL | PERM_SEND_MESSAGES)
	testing.expect_value(t, channel_permissions_of(&s, 302, 7, roles), u64(0))
	testing.expect_value(t, channel_permissions_of(&s, 999, 7, roles), u64(0))
	// the owner ignores overwrites
	testing.expect_value(t, channel_permissions_of(&s, 300, 1, nil), PERM_ALL)
}
