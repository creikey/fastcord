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

// Process-wide (several clients may parse messages at once): the heap and a lock.
// Entries are never removed, so their names stay valid.
sticker_items: Table(Snowflake, Sticker_Item);
sticker_mu: locks.Mutex;

#scope_export

// Called by the store while parsing a message's sticker_items.
note_sticker_items :: (s: *Store, l: []V) {
	if !l return;
	a := context.default_allocator;
	locks.lock(*sticker_mu);
	defer locks.unlock(*sticker_mu);
	sticker_items.allocator = a;
	for l {
		m := vmap(it);
		id := fsnow(m, "id");
		if id == 0 || table_contains(*sticker_items, id) continue;
		table_set(*sticker_items, id, .{id = id, name = clone_str(fstr(m, "name"), a), format_type = fint(m, "format_type")});
	}
}

// note_sticker records a sticker named elsewhere than sticker_items (inside an encrypted message).
note_sticker :: (id: Snowflake, name: string, format_type: int) {
	a := context.default_allocator;
	locks.lock(*sticker_mu);
	defer locks.unlock(*sticker_mu);
	sticker_items.allocator = a;
	if id && !table_contains(*sticker_items, id) table_set(*sticker_items, id, .{id = id, name = clone_str(name, a), format_type = format_type});
}

// Metadata for a sticker id seen in a message (or a guild's stickers).
sticker_item :: (s: *Store, id: Snowflake) -> Sticker_Item, bool {
	locks.lock(*sticker_mu);
	ok, item := table_find(*sticker_items, id);
	locks.unlock(*sticker_mu);
	if ok return item, true;
	for g: s.guilds for g.stickers if it.id == id return .{id, it.name, it.format_type}, true;
	return .{}, false;
}

