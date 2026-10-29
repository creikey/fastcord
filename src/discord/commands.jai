// Slash commands: the application command index (GET /guilds/{id}/application-command-index and
// /users/@me/application-command-index, loaded by open_message_context_menu), kept per guild (0: the user's
// own apps) for the composer's "/" autocomplete, and using one:
//   POST /interactions {"type":2, application_id, guild_id, channel_id, session_id,
//                       "data":{version, id, name, "type":1, options:[{type, name, value}], attachments:[]},
//                       nonce, "analytics_location":"slash_ui"}
// Untrusted: capped counts and lengths. No capture yet (traffic/CLIENT_RULES.md "Slash commands").

MAX_INDEX_COMMANDS :: 500;
MAX_COMMAND_OPTIONS :: 25;

Command_Option :: struct {
	kind: int; // 3 string, 4 integer, 5 boolean, 6 user, 7 channel, 8 role, 9 mentionable, 10 number
	name: string;
	description: string;
	required: bool;
}

App_Command :: struct {
	guild: Snowflake; // the index it came from (0: the user's)
	id: Snowflake;
	app_id: Snowflake;
	version: Snowflake;
	name: string;
	description: string;
	app_name: string;
	options: []Command_Option;
}

// Heap-owned, shared by the clients' workers (commands_mu).
command_index: [..]App_Command;
commands_mu: locks.Mutex;

// note_command_index: a 2xx index body (worker side, body in temp).
note_command_index :: (guild: Snowflake, body: V) {
	push_allocator(context.default_allocator);
	m := vmap(body);
	names: Table(Snowflake, string);
	names.allocator = temp;
	for flist(m, "applications") { am := vmap(it); table_set(*names, fsnow(am, "id"), fstr(am, "name")); }
	cut :: (t: string, n: int) -> string { return copy_string(slice(t, 0, min(t.count, n))); }
	locks.lock(*commands_mu);
	defer locks.unlock(*commands_mu);
	i := 0;
	while i < command_index.count {
		if command_index[i].guild == guild { free_command(*command_index[i]); array_unordered_remove_by_index(*command_index, i); }
		else i += 1;
	}
	for flist(m, "application_commands") {
		if it_index >= MAX_INDEX_COMMANDS break;
		cm := vmap(it);
		if vhas(cm, "type") && fint(cm, "type") != 1 continue; // chat input only, not context menu commands
		c := App_Command.{guild = guild, id = fsnow(cm, "id"), app_id = fsnow(cm, "application_id"), version = fsnow(cm, "version"),
			name = cut(fstr(cm, "name"), 32), description = cut(fstr(cm, "description"), 100)};
		_, an := table_find(*names, c.app_id);
		c.app_name = cut(an, 100);
		opts := flist(cm, "options");
		c.options = NewArray(min(opts.count, MAX_COMMAND_OPTIONS), Command_Option);
		for * c.options {
			om := vmap(opts[it_index]);
			it.* = .{kind = fint(om, "type"), name = cut(fstr(om, "name"), 32), description = cut(fstr(om, "description"), 100), required = fbool(om, "required")};
		}
		if c.id && c.app_id && c.name array_add(*command_index, c); else free_command(*c);
	}
}

free_command :: (c: *App_Command) {
	free(c.name); free(c.description); free(c.app_name);
	for c.options { free(it.name); free(it.description); }
	array_free(c.options);
}

// commands_for: the commands usable in a guild (its own and the user's apps), copied into temp.
commands_for :: (guild: Snowflake) -> []App_Command {
	out: [..]App_Command;
	out.allocator = temp;
	locks.lock(*commands_mu);
	defer locks.unlock(*commands_mu);
	for command_index if it.guild == guild || it.guild == 0 {
		c := it;
		c.name, c.description, c.app_name = copy_string(it.name,, temp), copy_string(it.description,, temp), copy_string(it.app_name,, temp);
		c.options = NewArray(it.options.count, Command_Option,, temp);
		for it.options c.options[it_index] = .{it.kind, copy_string(it.name,, temp), copy_string(it.description,, temp), it.required};
		array_add(*out, c);
	}
	return out;
}

Command_Value :: struct { option: Command_Option; value: string; } // value: as typed (a number or id stays a string)

// send_command_interaction: use cmd in channel_id with these option values.
send_command_interaction :: (c: *Client, cmd: App_Command, guild_id: Snowflake, channel_id: Snowflake, values: []Command_Value) {
	nonce := nonce_next(*c.id.nonces);
	w: Json;
	json_init(*w);
	json_obj(*w);
	json_kint(*w, "type", 2);
	json_ksnow(*w, "application_id", cmd.app_id);
	if guild_id json_ksnow(*w, "guild_id", guild_id);
	json_ksnow(*w, "channel_id", channel_id);
	json_kstr(*w, "session_id", c.store.session_id);
	json_key(*w, "data");
	json_obj(*w);
	json_ksnow(*w, "version", cmd.version);
	json_ksnow(*w, "id", cmd.id);
	json_kstr(*w, "name", cmd.name);
	json_kint(*w, "type", 1);
	json_key(*w, "options");
	json_arr(*w);
	for values {
		json_obj(*w);
		json_kint(*w, "type", it.option.kind);
		json_kstr(*w, "name", it.option.name);
		json_key(*w, "value");
		if it.option.kind == {
			case 4; #through; case 10; json_raw(*w, it.value); // checked numeric by the caller
			case 5; json_bool(*w, it.value == "true");
			case; json_str(*w, it.value);
		}
		json_obj_end(*w);
	}
	json_arr_end(*w);
	json_key(*w, "attachments");
	json_arr(*w);
	json_arr_end(*w);
	json_obj_end(*w);
	json_ksnow(*w, "nonce", nonce);
	json_kstr(*w, "analytics_location", "slash_ui");
	json_obj_end(*w);
	f_submit(c, .{op = .Guild_Aux, channel_id = channel_id, method = "POST", path = "/interactions", body = json_string(*w)});
}
