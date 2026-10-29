// block_user: PUT /users/@me/relationships/{id} {"type":2}, with an
// X-Context-Properties location naming where it was clicked (like add_relationship).
block_user :: (c: *Client, user_id: Snowflake, location := "ContextMenu") {
	j := job_new(.Api, .Relationship);
	j.method = "PUT";
	j.path = job_str(j, tprint("/users/@me/relationships/%", user_id));
	j.body = cast([]u8) "{\"type\":2}";
	j.content_type = "application/json";
	j.context_b64 = job_str(j, context_location(location));
	j.result.user_id = user_id;
	job_submit(c, j);
}

// ignore_user: Ignore / Unignore, PUT / DELETE /users/@me/relationships/{id}/ignore with no body; the
// relationship's user_ignored follows from RELATIONSHIP_UPDATE.
ignore_user :: (c: *Client, user_id: Snowflake, ignore: bool, location := "ContextMenu") {
	j := job_new(.Api, .Relationship);
	j.method = ifx ignore then "PUT" else "DELETE";
	j.path = job_str(j, tprint("/users/@me/relationships/%/ignore", user_id));
	j.context_b64 = job_str(j, context_location(location));
	j.result.user_id = user_id;
	job_submit(c, j);
}

// close_private_channel: closing a DM (or leaving a group DM) from the DM list:
// DELETE /channels/{id}?silent=false. The gateway's CHANNEL_DELETE removes it.
close_private_channel :: (c: *Client, channel_id: Snowflake) {
	j := job_new(.Api, .None);
	j.method = "DELETE";
	j.path = job_str(j, tprint("/channels/%?silent=false", channel_id));
	job_submit(c, j);
}

// ring_call: starting a DM / group DM call rings the other recipients:
// POST /channels/{id}/call/ring {"recipients":null} (after op 4 joins the call).
ring_call :: (c: *Client, channel_id: Snowflake) {
	j := job_new(.Api, .None);
	j.method = "POST";
	j.path = job_str(j, channel_path(channel_id, "/call/ring"));
	j.body = cast([]u8) "{\"recipients\":null}";
	j.content_type = "application/json";
	job_submit(c, j);
}

