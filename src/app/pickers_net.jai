// Expression picker network results (discord/expressions.jai) -> picker state.

// The client for the pickers' Discord requests (GIFs, frecency): Discord's even while a hosted server is
// selected, since a hosted server has neither; null with no Discord login.
expr_client :: () -> *dc.Client { return ifx on_hosted() then app.discord else app.client; }

pickers_first_open :: () {
	emoji_db_load();
	c := expr_client();
	if c == null return;
	// FrecencyUserSettings are loaded lazily (loadIfNecessary) when a picker needs them.
	if !frecency.loaded_server dc.frecency_settings_fetch(c);
}

// Per open: the guild's top emojis once per session, like the client's picker. The session's first
// open also loads the subscriptions and our own profile (dc.open_emoji_picker, fixture add_reaction).
// A hosted server has no top emojis.
pickers_on_open_guild :: (gid: dc.Snowflake) {
	if app.client == null || on_hosted() return;
	if !app.client.emoji_picker_opened {
		if gid table_add(*top_emojis_fetched, gid, true);
		dc.open_emoji_picker(app.client, gid);
		return;
	}
	if gid == 0 || table_contains(*top_emojis_fetched, gid) return;
	table_add(*top_emojis_fetched, gid, true);
	dc.guild_top_emojis(app.client, gid);
}

pickers_poll :: () {
	if app.discord != null && app.discord.store.frecency.remote != frecency.remote_seen {
		frecency.remote_seen = app.discord.store.frecency.remote;
		fs, ok := dc.frecency_settings_decode(app.discord.store.frecency.proto, temp);
		if ok frecency_merge_server(fs, remote = true);
	}
	for c: (*dc.Client).[app.client, app.discord] {
		if c == null || (it_index == 1 && c == app.client) continue;
		for * r: dc.expr_take(c) {
			defer dc.expr_result_free(c, r);
			pickers_result(r);
		}
	}
}

// Offline (fixture) runs: an API body from FASTCORD_MEDIA_DIR, named by the path's last component.
pickers_offline :: (op: dc.Expr_Op, name: string) {
	data, ok := offline_media(name);
	if !ok return;
	body, err := etf.from_json(cast(string) data,, temp);
	r := dc.Expr_Result.{op = op, ok = err == .None, status = 200, body = body};
	pickers_result(*r);
}

#scope_file

pickers_result :: (r: *dc.Expr_Result) {
	if r.op == {
	case .Frecency;
		sp := ifx r.ok then dc.fstr(dc.vmap(r.body), "settings") else "";
		if sp != "" {
			fs, ok := dc.frecency_settings_decode(sp, temp);
			if ok {
				frecency_merge_server(fs);
				if pickers_debug() print("[pickers] frecency: % emoji, % reaction, % sticker, % fav emoji, % fav gifs\n", fs.emoji.count, fs.emoji_reaction.count, fs.sticker.count, fs.favorite_emojis.count, fs.favorite_gifs.count, to_standard_error = true);
			}
		}
		frecency.loaded_server = true;
	case .Gif_Trending; #through;
	case .Gif_Trending_Gifs; #through;
	case .Gif_Search; #through;
	case .Gif_Suggest;
		gif_receive(r);
	case .Sticker_Packs;
		sticker_packs_receive(r);
	case .Media;
		lottie_receive(r);
	case .Profile_Modal; #through;
	case .Mutual_Friends; #through;
	case .App_Identities;
		profile_full_receive(r);
	case .Gif_Select; #through;
	case .Top_Emojis;
		if pickers_debug() print("[pickers] % status=% body=%\n", r.op, r.status, r.body, to_standard_error = true);
	}
}

top_emojis_fetched: Table(dc.Snowflake, bool);
