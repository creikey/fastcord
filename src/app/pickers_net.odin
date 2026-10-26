package app

import dc "fc:discord"

// Expression picker network results (src/discord/expressions.odin) -> picker state.

pickers_first_open :: proc() {
	emoji_db_load()
	frecency_load_local()
	if app.client == nil do return
	// FrecencyUserSettings are loaded lazily (loadIfNecessary) when a picker needs them.
	if !frecency.loaded_server do dc.frecency_settings_fetch(app.client)
}

@(private = "file")
top_emojis_fetched: map[dc.Snowflake]bool

// Per open: the guild's top emojis once per session, like the client's picker.
pickers_on_open_guild :: proc(gid: dc.Snowflake) {
	if app.client == nil || gid == 0 || top_emojis_fetched[gid] do return
	top_emojis_fetched[gid] = true
	dc.guild_top_emojis(app.client, gid)
}

pickers_poll :: proc() {
	if app.client == nil do return
	for &r in dc.expr_take(app.client) {
		defer dc.expr_result_free(app.client, &r)
		switch r.op {
		case .Frecency:
			if r.ok {
				if sp := dc.fstr(dc.vmap(r.body), "settings"); sp != "" {
					if fs, ok := dc.frecency_settings_decode(sp, context.temp_allocator); ok do frecency_merge_server(fs)
				}
			}
			frecency.loaded_server = true
		case .Gif_Trending, .Gif_Trending_Gifs, .Gif_Search, .Gif_Suggest:
			gif_receive(&r)
		case .Sticker_Packs:
			sticker_packs_receive(&r)
		case .Media:
			lottie_receive(&r)
		case .Gif_Select, .Top_Emojis:
		}
	}
}
