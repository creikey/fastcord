package discord

import "core:strings"

// block_user: PUT /users/@me/relationships/{id} {"type":2}, with an
// X-Context-Properties location naming where it was clicked (like add_relationship).
block_user :: proc(c: ^Client, user_id: Snowflake, location := "ContextMenu") {
	j := job_new(.Api, .Relationship)
	j.method = "PUT"
	j.path = job_str(j, strings.concatenate({"/users/@me/relationships/", snowflake_string(user_id)}, context.temp_allocator))
	j.body = transmute([]byte)job_str(j, `{"type":2}`)
	j.content_type = "application/json"
	j.context_b64 = job_str(j, context_location(location))
	j.result.user_id = user_id
	job_submit(c, j)
}

// close_private_channel: closing a DM (or leaving a group DM) from the DM list:
// DELETE /channels/{id}?silent=false. The gateway's CHANNEL_DELETE removes it.
close_private_channel :: proc(c: ^Client, channel_id: Snowflake) {
	j := job_new(.Api, .None)
	j.method = "DELETE"
	j.path = job_str(j, strings.concatenate({"/channels/", snowflake_string(channel_id), "?silent=false"}, context.temp_allocator))
	job_submit(c, j)
}
