// Draft attachments, as the official client handles them (traffic/upload_options.jsonl):
//   - staging a file starts its upload at once: science attachment_upload_started,
//     POST /channels/{c}/attachments {"files":[{filename,file_size,id,is_clip,original_content_type}]},
//     CORS preflight + PUT of the bytes to the returned upload_url, science attachment_upload_finished;
//   - spoiler / rename / description change nothing on the wire until the message is sent
//     (science media_draft_edited only);
//   - removing an uploaded draft fires DELETE /attachments/<upload_filename, '/' as %2F> once,
//     never retried (the capture got a 429 and the client left it), plus a second
//     attachment_upload_finished with final_state REMOVED_FROM_MSG_DRAFT;
//   - Send posts the message with attachments [{id:"<index>",description?,filename,
//     uploaded_filename,is_spoiler?,original_content_type}], after the uploads finish.









Draft_State :: enum u8 {
	Uploading;
	Done;
	Failed;
}

Draft_Upload :: struct {
	handle: u64;
	channel_id: Snowflake;
	filename: string; // the name the file was staged with (upload_filename keeps it)
	mime: string;
	origin: string; // science origin: "file_picker", "clipboard", ...
	size: s64; // bytes uploaded (the WebP when converted)
	pre_size: s64; // the staged file's size
	conv: Webp_Conversion; // data dropped once uploaded
	state: Draft_State;
	sent: s64; // bytes acknowledged (0 until the PUT completes: the PUT is one body)
	upload_filename: string;
	removed: bool; // removed from the draft while uploading: clean up when it lands
	start_ms: float64;
	get_url_ms: float64;
	upload_ms: float64;
}

// One staged attachment of a message being sent (Send_Options.attachments).
Draft_Attachment :: struct {
	handle: u64;
	filename: string; // display name (may be renamed)
	description: string; // alt text ("" = none)
	spoiler: bool;
}
#scope_module

Drafts :: struct {
	mu: locks.Mutex;
	list: [..]*Draft_Upload;
	seq: u64;
}

drafts_of :: (c: *Client) -> *Drafts {
	if c.drafts == null { c.drafts = new(Drafts, context.default_allocator); }
	return c.drafts;
}

drafts_destroy :: (c: *Client) {
	d := c.drafts;
	if is_null(d) { return; }
	a := context.default_allocator;
	for u: d.list { draft_free(u); }
	delete(d.list);
	free(d,, a);
	c.drafts = null;
}

draft_free :: (u: *Draft_Upload) {
	a := context.default_allocator;
	delete(u.filename, a);
	delete(u.mime, a);
	delete(u.origin, a);
	delete(u.upload_filename, a);
	free(u,, a);
}

draft_find :: (d: *Drafts, handle: u64) -> *Draft_Upload, int {
	for u, i: d.list { if u.handle == handle { return u, i; } }
	return null, -1;
}
#scope_export

// upload_draft starts uploading a staged file (UI thread). data is copied.
// Returns a handle for upload_draft_status / upload_draft_remove / Send_Options.attachments.
upload_draft :: (c: *Client, channel_id: Snowflake, filename: string, mime: string, data: []u8, origin := "file_picker") -> u64 {
	a := context.default_allocator;
	d := drafts_of(c);
	u := new(Draft_Upload, a);
	u.channel_id = channel_id;
	u.filename = clone(filename, a);
	u.mime = clone(mime, a);
	u.origin = clone(origin, a);
	u.size = cast(s64)(len(data));
	u.pre_size = u.size;
	u.start_ms = now_ms_f();
	locks.lock(*d.mu);
	d.seq += 1;
	u.handle = d.seq;
	append(*d.list, u);
	locks.unlock(*d.mu);

	j := job_new(.Upload, .Upload);
	al := job_alloc(j);
	j.files = make_slice(Upload_File, 1, al);
	j.files[0] = Upload_File.{clone(filename, al), clone(mime, al), clone(data, al)};
	j.result = Rest_Result.{op = .Upload, channel_id = channel_id, tag = u.handle};
	j.draft = u.handle;
	job_submit(c, j);
	return u.handle;
}

// upload_draft_status: where a draft's upload is (any thread).
upload_draft_status :: (c: *Client, handle: u64) -> Draft_State, s64, s64, bool {
	state: Draft_State;
	sent: s64;
	total: s64;
	ok: bool;
	if c == null || c.drafts == null { return state, sent, total, ok; }
	d := c.drafts;
	locks.lock(*d.mu);
	defer locks.unlock(*d.mu);
	u, _ := draft_find(d, handle);
	if u == null { return state, sent, total, ok; }
	return u.state, u.sent, u.size, true;
}

// upload_draft_remove: the trash button. An uploaded file is deleted from the bucket
// (fire and forget); one still uploading is deleted when its upload lands.
upload_draft_remove :: (c: *Client, handle: u64) {
	d := drafts_of(c);
	locks.lock(*d.mu);
	u, i := draft_find(d, handle);
	if u == null {
		locks.unlock(*d.mu);
		return;
	}
	if u.state == {
	case .Uploading;
		u.removed = true;
		locks.unlock(*d.mu);
		return;
	case .Failed;
		ordered_remove(*d.list, i);
		locks.unlock(*d.mu);
		draft_free(u);
		return;
	case .Done;
		ordered_remove(*d.list, i);
	}
	locks.unlock(*d.mu);
	draft_delete_remote(c, u);
	draft_free(u);
}
#scope_module

// upload_draft_release forgets a draft that was sent with a message (its file now belongs to the message).
upload_draft_release :: (c: *Client, handle: u64) {
	d := drafts_of(c);
	locks.lock(*d.mu);
	u, i := draft_find(d, handle);
	if u != null { ordered_remove(*d.list, i); }
	locks.unlock(*d.mu);
	if u != null { draft_free(u); }
}

draft_delete_remote :: (c: *Client, u: *Draft_Upload) {
	if u.upload_filename == "" { return; }
	j := job_new(.Api, .None);
	j.method = "DELETE";
	enc, _ := strings.replace_all(u.upload_filename, "/", "%2F", temp);
	j.path = job_str(j, strings.concatenate(string.["/attachments/", enc], temp));
	j.retries = 0; // the client does not retry this cleanup, not even after a 429
	j.retry_429 = 0;
	job_submit(c, j);
	analytics_upload_finished(c, u, "REMOVED_FROM_MSG_DRAFT", now_ms_f() - u.start_ms);
}
#scope_export

// attachments array for the message POST (key order of the capture).
attachments_json :: (atts: []Draft_Attachment, uploaded: []string, mimes: []string, allocator := temp) -> string {
	w: Json;
	json_init(*w, allocator);
	json_arr(*w);
	for a, i: atts {
		json_obj(*w);
		json_kstr(*w, "id", itoa(i));
		if a.description != "" { json_kstr(*w, "description", a.description); }
		json_kstr(*w, "filename", a.filename);
		json_kstr(*w, "uploaded_filename", uploaded[i]);
		if a.spoiler { json_kbool(*w, "is_spoiler", true); }
		if mimes[i] != "" { json_kstr(*w, "original_content_type", mimes[i]); }
		json_obj_end(*w);
	}
	json_arr_end(*w);
	return json_string(*w);
}
#scope_module

// Worker: the upload of one draft (job.draft != 0).
run_draft_upload :: (c: *Client, j: *Job) {
	d := drafts_of(c);
	f := j.files[0];
	locks.lock(*d.mu);
	u, _ := draft_find(d, j.draft);
	locks.unlock(*d.mu);
	if u == null { return; }
	analytics_upload_started(c, u);
	// the client's WebP "mezzanine" conversion, before asking for the upload URL
	conv := webp_try_convert(atomic_load(*c.webp_variation), f.mime, f.data);
	if conv.converted { f.data = conv.data; }
	locks.lock(*d.mu);
	u.conv = conv;
	u.conv.data = zero(type_of(u.conv.data));
	u.size = cast(s64)(len(f.data));
	locks.unlock(*d.mu);
	name, ok, url_ms, put_ms := upload_one(c, u.channel_id, f);
	a := context.default_allocator;
	locks.lock(*d.mu);
	u.get_url_ms = url_ms;
	u.upload_ms = put_ms;
	if ok {
		u.upload_filename = clone(name, a);
		u.state = .Done;
		u.sent = u.size;
	} else {
		u.state = .Failed;
	}
	removed := u.removed;
	if removed {
		_, i := draft_find(d, u.handle);
		if i >= 0 { ordered_remove(*d.list, i); }
	}
	locks.unlock(*d.mu);
	if ok { analytics_upload_finished(c, u, "COMPLETED", now_ms_f() - u.start_ms); }
	if removed {
		if ok { draft_delete_remote(c, u); }
		draft_free(u);
	}
	client_push_event(c, Event.{kind = .Rest, result = Rest_Result.{op = .None, tag = j.draft, ok = ok}});
}

// Worker: the message POST of a send with drafts; waits (requeues) while any is uploading.
run_draft_send :: (c: *Client, j: *Job) -> bool {
	requeue: bool;
	d := drafts_of(c);
	atts := j.drafts;
	uploaded := make_slice(string, len(atts), temp);
	mimes := make_slice(string, len(atts), temp);
	failed := false;
	locks.lock(*d.mu);
	for a, i: atts {
		u, _ := draft_find(d, a.handle);
		if u == null || u.state == .Failed {
			failed = true;
			continue;
		}
		if u.state == .Uploading {
			locks.unlock(*d.mu);
			return true;
		}
		uploaded[i] = clone(u.upload_filename, temp);
		mimes[i] = clone(u.mime, temp);
	}
	locks.unlock(*d.mu);
	for a: atts { upload_draft_release(c, a.handle); }
	if failed {
		client_push_event(c, Event.{kind = .Rest, result = Rest_Result.{op = .Send_Message, channel_id = j.result.channel_id, nonce = j.result.nonce, ok = false}});
		return false;
	}
	body := j.message_json(j, attachments_json(atts, uploaded, mimes));
	r := api_call(c, "POST", j.path, body, "application/json", j.context_b64, .[], 3, 1);
	j.result.op = .Send_Message;
	push_result(c, j, r);
	return false;
}

// One file: POST /attachments for an upload URL, then preflight + PUT. Returns upload_filename.
upload_one :: (c: *Client, channel_id: Snowflake, f: Upload_File) -> string, bool, float64, float64 {
	name: string;
	ok: bool;
	url_ms: float64;
	put_ms: float64;
	t0 := now_ms_f();
	w: Json;
	json_init(*w);
	json_obj(*w);
	json_key(*w, "files");
	json_arr(*w);
	json_obj(*w);
	json_kstr(*w, "filename", f.filename);
	json_kint(*w, "file_size", cast(s64)(len(f.data)));
	locks.lock(*c.job_mu);
	c.upload_seq += 1;
	uid := c.upload_seq;
	locks.unlock(*c.job_mu);
	json_kstr(*w, "id", itoa(uid));
	json_kbool(*w, "is_clip", false);
	if f.mime != "" { json_kstr(*w, "original_content_type", f.mime); }
	json_obj_end(*w);
	json_arr_end(*w);
	json_obj_end(*w);
	body := transmute([]u8, json_string(*w));
	r := api_call(c, "POST", strings.concatenate(string.["/channels/", snowflake_string(channel_id), "/attachments"], temp), body, "application/json", "", .[], 0, 0);
	url_ms = now_ms_f() - t0;
	defer if r.arena != null {
		fini(r.arena);
		free(r.arena);
	}
	if !r.ok { return name, ok, url_ms, put_ms; }
	att := flist(vmap(r.body), "attachments");
	if len(att) == 0 { return name, ok, url_ms, put_ms; }
	up_url := clone(fstr(vmap(att[0]), "upload_url"), temp);
	name = clone(fstr(vmap(att[0]), "upload_filename"), temp);
	t1 := now_ms_f();
	ok = upload_put(c, up_url, f.data);
	put_ms = now_ms_f() - t1;
	return name, ok, url_ms, put_ms;
}

// ---- science (shapes from traffic/upload_options.jsonl) ----

analytics_upload_started :: (c: *Client, u: *Draft_Upload) {
	w: Json;
	json_init(*w);
	json_obj(*w);
	json_kint(*w, "file_size", u.size);
	json_kstr(*w, "mime_type", u.mime);
	json_kstr(*w, "video_upload_quality", "standard");
	json_kbool(*w, "data_saving_mode", false);
	json_kbool(*w, "low_quality_image_mode", false);
	json_ksnow(*w, "channel_id", u.channel_id);
	json_kstr(*w, "connection_type", "unknown");
	json_kstr(*w, "effective_connection_speed", "4g");
	json_obj_end(*w);
	analytics_track(c, "attachment_upload_started", json_body(json_string(*w)));
}

// attachment_upload_finished, keys in the client's order; undefined values are left out
// as JSON.stringify does (compress_time_ms / conversion_failure_reason without a conversion
// attempt, hash_time_ms unless converted).
analytics_upload_finished :: (c: *Client, u: *Draft_Upload, final_state: string, duration_ms: float64) {
	w: Json;
	json_init(*w);
	json_obj(*w);
	json_key(*w, "duration_ms");
	json_raw(*w, js_ms(max(duration_ms, 0)));
	json_kint(*w, "file_size", u.size);
	json_kint(*w, "pre_compression_file_size", u.pre_size);
	json_kstr(*w, "final_state", final_state);
	json_kstr(*w, "mime_type", u.mime);
	json_kint(*w, "num_upload_attempts", 1);
	json_kstr(*w, "video_upload_quality", "standard");
	json_kbool(*w, "data_saving_mode", false);
	json_kbool(*w, "low_quality_image_mode", false);
	if u.conv.attempted { json_kint(*w, "compress_time_ms", u.conv.compress_ms); }
	json_key(*w, "get_upload_url_time_ms");
	json_raw(*w, js_ms(u.get_url_ms));
	json_key(*w, "upload_time_ms");
	json_raw(*w, js_ms(u.upload_ms));
	json_kstr(*w, "converted_mime_type", ifx u.conv.converted then "image/webp" else "unknown");
	json_kint(*w, "image_compression_quality", 0);
	json_kstr(*w, "video_compression_quality", "unknown");
	json_kstr(*w, "image_encoder_type", "unknown");
	json_kbool(*w, "was_converted", u.conv.converted);
	json_kbool(*w, "was_compressed", u.size < u.pre_size);
	json_ksnow(*w, "channel_id", u.channel_id);
	if u.conv.converted {
		json_key(*w, "hash_time_ms");
		json_raw(*w, js_ms(u.conv.hash_ms));
	}
	json_kstr(*w, "origin", u.origin);
	json_kint(*w, "upload_resumption_count", 0);
	json_kint(*w, "upload_resumption_position", 0);
	if u.conv.failure != "" { json_kstr(*w, "conversion_failure_reason", u.conv.failure); }
	json_kstr(*w, "upload_http_client", "httputils");
	json_kstr(*w, "connection_type", "unknown");
	json_kstr(*w, "effective_connection_speed", "4g");
	json_obj_end(*w);
	analytics_track(c, "attachment_upload_finished", json_body(json_string(*w)));
}
#scope_export

// media_draft_edited: the spoiler toggle sends {"spoilered":bool}; Modify > Save sends {"has_alt_text":bool}.
analytics_media_draft_edited :: (c: *Client, key: string, value: bool) {
	if c == null { return; }
	analytics_track(c, "media_draft_edited", fmt.tprintf("\"%s\":%v", key, value));
}
#scope_module

// A performance.now() difference as JSON.stringify prints it: 0.1 ms resolution
// (Chromium's coarsened clock), no ".0" on whole numbers.
js_ms :: (ms: float64) -> string {
	tenths := cast(s64)(max(ms, 0) * 10 + 0.5);
	if tenths % 10 == 0 { return fmt.tprintf("%d", tenths / 10); }
	return fmt.tprintf("%d.%d", tenths / 10, tenths % 10);
}
#scope_export

