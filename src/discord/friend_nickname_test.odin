package discord

import "core:testing"
import "fc:etf"

@(test)
user_name_precedence :: proc(t: ^testing.T) {
	s: Store
	store_init(&s, context.temp_allocator)
	apply :: proc(s: ^Store, ev, json: string) {
		d, _ := etf.from_json(json, context.temp_allocator)
		store_apply_dispatch(s, ev, d, 0)
	}
	testing.expect_value(t, user_name(&s, 11, 0, "Unknown"), "Unknown")
	apply(&s, "RELATIONSHIP_ADD", `{"id":"11","type":1,"nickname":null,"user":{"id":"11","username":"ann","global_name":null}}`)
	testing.expect_value(t, user_name(&s, 11), "ann")
	apply(&s, "USER_UPDATE", `{"id":"11","username":"ann","global_name":"Ann Global"}`)
	testing.expect_value(t, user_name(&s, 11), "Ann Global")
	// fixture friend_nickname: outside guilds the friend nickname beats the global
	// name; in a guild it is ignored (server nick > global name > username)
	apply(&s, "RELATIONSHIP_UPDATE", `{"id":"11","type":1,"nickname":"Annie"}`)
	testing.expect_value(t, user_name(&s, 11), "Annie")
	testing.expect_value(t, user_name(&s, 11, 1), "Ann Global")
	// a server nickname shows in that server only; outside guilds it is ignored
	apply(&s, "GUILD_MEMBER_UPDATE", `{"guild_id":"1","nick":"Server Ann","roles":[],"user":{"id":"11","username":"ann","global_name":"Ann Global"}}`)
	testing.expect_value(t, user_name(&s, 11, 1), "Server Ann")
	testing.expect_value(t, user_name(&s, 11, 2), "Ann Global")
	testing.expect_value(t, user_name(&s, 11), "Annie")
	// server nickname set / cleared (optimistic): "" falls back to the global name
	store_set_server_nickname(&s, 1, 11, "")
	testing.expect_value(t, user_name(&s, 11, 1), "Ann Global")
	// optimistic edit, then the gateway clearing it with null
	store_set_friend_nickname(&s, 11, "Nan")
	testing.expect_value(t, friend_nickname(&s, 11), "Nan")
	apply(&s, "RELATIONSHIP_UPDATE", `{"id":"11","type":1,"nickname":null}`)
	testing.expect_value(t, user_name(&s, 11), "Ann Global")
	// unfriending drops the nickname
	apply(&s, "RELATIONSHIP_UPDATE", `{"id":"11","type":1,"nickname":"Annie"}`)
	apply(&s, "RELATIONSHIP_REMOVE", `{"id":"11","type":1}`)
	testing.expect_value(t, user_name(&s, 11), "Ann Global")
}
