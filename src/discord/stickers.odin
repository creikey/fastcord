package discord

// Message sticker items ({id, name, format_type} from messages' sticker_items).
// Messages keep only the ids (Message.sticker_ids); the item metadata lives in
// this side table, keyed by sticker id, so views can pick the right renderer:
// 1 png, 2 apng, 4 gif -> media proxy image; 3 lottie -> discord.com/stickers/<id>.json.

Sticker_Item :: struct {
	id:          Snowflake,
	name:        string,
	format_type: int,
}

@(private = "file")
sticker_items: map[Snowflake]Sticker_Item

// Called by the store while parsing a message's sticker_items.
note_sticker_items :: proc(s: ^Store, l: []V) {
	for sv in l {
		sm := vmap(sv)
		id := fsnow(sm, "id")
		if id == 0 || id in sticker_items do continue
		sticker_items[id] = Sticker_Item {
			id          = id,
			name        = clone_str(fstr(sm, "name"), s.allocator),
			format_type = int(fint(sm, "format_type")),
		}
	}
}

// Metadata for a sticker id seen in a message (or a guild's stickers).
sticker_item :: proc(s: ^Store, id: Snowflake) -> (Sticker_Item, bool) {
	if it, ok := sticker_items[id]; ok do return it, true
	for _, &g in s.guilds {
		for st in g.stickers do if st.id == id do return {id, st.name, st.format_type}, true
	}
	return {}, false
}
