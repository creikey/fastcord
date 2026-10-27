// Message sticker items ({id, name, format_type} from messages' sticker_items).
// Messages keep only the ids (Message.sticker_ids); the item metadata lives in
// this side table, keyed by sticker id, so views can pick the right renderer:
// 1 png, 2 apng, 4 gif -> media proxy image; 3 lottie -> discord.com/stickers/<id>.json.

Sticker_Item :: struct {
	id: Snowflake;
	name: string;
	format_type: int;
}
#scope_file

sticker_items: Table(Snowflake, Sticker_Item);
#scope_export

// Called by the store while parsing a message's sticker_items.
note_sticker_items :: (s: *Store, l: []V) {
	for sv: l {
		sm := vmap(sv);
		id := fsnow(sm, "id");
		if id == 0 || table_contains(*sticker_items, id) { continue; }
		find_or_add(*sticker_items, id).* = Sticker_Item.{
			id = id,
			name = clone_str(fstr(sm, "name"), s.allocator),
			format_type = cast(int)(fint(sm, "format_type"))
		};
	}
}

// Metadata for a sticker id seen in a message (or a guild's stickers).
sticker_item :: (s: *Store, id: Snowflake) -> Sticker_Item, bool {
	{ ok, it_ := table_find(*sticker_items, id);
	if ok { return it_, true; } }
	for * g: s.guilds {
		for st: g.stickers { if st.id == id { return .{id, st.name, st.format_type}, true; } }
	}
	return .{}, false;
}

