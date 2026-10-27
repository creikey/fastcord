// Expression picker network results (src/discord/expressions.odin) -> picker state.

pickers_first_open :: () {
	emoji_db_load();
	frecency_load_local();
	if app.client == null { return; }
	// FrecencyUserSettings are loaded lazily (loadIfNecessary) when a picker needs them.
	if !frecency.loaded_server { dc.frecency_settings_fetch(app.client); }
}
#scope_file

top_emojis_fetched: Map(dc.Snowflake, bool);
#scope_export

// Per open: the guild's top emojis once per session, like the client's picker.
pickers_on_open_guild :: (gid: dc.Snowflake) {
	if app.client == null || gid == 0 || get(top_emojis_fetched, gid) { return; }
	at(*top_emojis_fetched, gid).* = true;
	dc.guild_top_emojis(app.client, gid);
}

pickers_poll :: () {
	if app.client == null { return; }
	for * r: dc.expr_take(app.client) {
		defer dc.expr_result_free(app.client, r);
		if r.op == {
		case .Frecency;
			if r.ok {
				{ sp := dc.fstr(dc.vmap(r.body), "settings");
				if sp != "" {
					{ fs, ok := dc.frecency_settings_decode(sp, temp);
					if ok {
						frecency_merge_server(fs);
						if pickers_debug() { fmt.eprintfln("[pickers] frecency: %d emoji, %d reaction, %d sticker, %d fav emoji, %d fav gifs", len(fs.emoji), len(fs.emoji_reaction), len(fs.sticker), len(fs.favorite_emojis), len(fs.favorite_gifs)); }
					} }
				} }
			}
			frecency.loaded_server = true;
		case .Gif_Trending; #through; case .Gif_Trending_Gifs; #through; case .Gif_Search; #through; case .Gif_Suggest;
			gif_receive(r);
		case .Sticker_Packs;
			sticker_packs_receive(r);
		case .Media;
			lottie_receive(r);
		case .Profile_Modal; #through; case .Mutual_Friends; #through; case .App_Identities;
			profile_full_receive(r);
		case .Gif_Select; #through; case .Top_Emojis;
			if pickers_debug() { fmt.eprintfln("[pickers] %v status=%d body=%v", r.op, r.status, r.body); }
		}
	}
}

