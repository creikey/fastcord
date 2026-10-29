// Polls: a message's `poll` (question, answers, expiry, results), the votes that change it
// (MESSAGE_POLL_VOTE_ADD/REMOVE) and voting:
//   PUT  /channels/{c}/polls/{m}/answers/@me {"answer_ids":["1"]}   (an empty list takes the vote back)
//   POST /channels/{c}/polls/{m}/expire                               (End Poll Now, the author)

MAX_POLL_ANSWERS :: 10;

Poll_Answer :: struct {
	id: int;
	text: string;  // store-owned
	emoji: string; // a Unicode emoji, store-owned; "" for none
	count: int;
	me: bool;
}

Poll :: struct {
	question: string; // store-owned
	answers: [..]Poll_Answer;
	expiry: string;   // ISO 8601, store-owned
	multiselect: bool;
	finalized: bool;
	counted: bool;    // results arrived (a fetch or an update); before that the counts are unknown
}

// parse_poll fills msg.poll from a message's `poll`. Untrusted: at most MAX_POLL_ANSWERS answers.
parse_poll :: (s: *Store, msg: *Message, m: etf.Map) {
	if !m return;
	if !msg.poll {
		msg.poll = New(Poll,, s.allocator);
		msg.poll.answers.allocator = s.allocator;
	}
	p := msg.poll;
	if vhas(m, "question") set_str(s, *p.question, fstr(fmap(m, "question"), "text"));
	if vhas(m, "expiry") set_str(s, *p.expiry, fstr(m, "expiry"));
	if vhas(m, "allow_multiselect") p.multiselect = fbool(m, "allow_multiselect");
	if vhas(m, "answers") {
		for p.answers { free_str(it.text, s.allocator); free_str(it.emoji, s.allocator); }
		p.answers.count = 0;
		for flist(m, "answers") {
			if p.answers.count == MAX_POLL_ANSWERS break;
			am := vmap(it);
			media := fmap(am, "poll_media");
			emoji := fmap(media, "emoji");
			array_add(*p.answers, .{id = fint(am, "answer_id"), text = clone_str(fstr(media, "text"), s.allocator), emoji = clone_str(ifx fsnow(emoji, "id") then "" else fstr(emoji, "name"), s.allocator)});
		}
	}
	results := fmap(m, "results");
	if results {
		p.finalized = fbool(results, "is_finalized");
		p.counted = true;
		for * p.answers { it.count = 0; it.me = false; }
		for flist(results, "answer_counts") {
			c := vmap(it);
			for * p.answers if it.id == fint(c, "id") { it.count = fint(c, "count"); it.me = fbool(c, "me_voted"); }
		}
	}
}

free_poll :: (s: *Store, p: *Poll) {
	if !p return;
	for p.answers { free_str(it.text, s.allocator); free_str(it.emoji, s.allocator); }
	array_free(p.answers);
	free_str(p.question, s.allocator);
	free_str(p.expiry, s.allocator);
	free(p,, s.allocator);
}

// apply_poll_vote: MESSAGE_POLL_VOTE_ADD (add) or _REMOVE for a message we have.
apply_poll_vote :: (s: *Store, d: etf.Map, add: bool) {
	l := table_find_pointer(*s.messages, fsnow(d, "channel_id"));
	i := ifx l then message_index(l, fsnow(d, "message_id")) else -1;
	if i < 0 || !l.messages[i].poll return;
	p := l.messages[i].poll;
	for * p.answers if it.id == fint(d, "answer_id") {
		it.count = max(0, it.count + ifx add then 1 else -1);
		if fsnow(d, "user_id") == s.me it.me = add;
	}
}

// poll_vote: our answers (none takes the vote back); the gateway's vote events update the counts.
poll_vote :: (c: *Client, channel_id: Snowflake, message_id: Snowflake, answer_ids: []int) {
	w: Json;
	json_init(*w);
	json_obj(*w);
	json_key(*w, "answer_ids");
	json_arr(*w);
	for answer_ids json_str(*w, tprint("%", it));
	json_arr_end(*w);
	json_obj_end(*w);
	j := job_new(.Api, .None);
	j.method = "PUT";
	j.path = job_str(j, channel_path(channel_id, "/polls/", snowflake_string(message_id), "/answers/@me"));
	j.body = cast([]u8) job_str(j, json_string(*w));
	j.content_type = "application/json";
	job_submit(c, j);
}

// poll_expire: End Poll Now; the message comes back finalized in a MESSAGE_UPDATE.
poll_expire :: (c: *Client, channel_id: Snowflake, message_id: Snowflake) {
	j := job_new(.Api, .None);
	j.method = "POST";
	j.path = job_str(j, channel_path(channel_id, "/polls/", snowflake_string(message_id), "/expire"));
	job_submit(c, j);
}
