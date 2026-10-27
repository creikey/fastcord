#scope_file

// OS notifications and the dock badge.
//
// Notifications use UNUserNotificationCenter, which only works for a process
// with a bundle identifier (an .app bundle); an unbundled binary gets no
// center (the API raises), so notify_show reports false there and callers
// still get the sound and badge. Authorization is requested once, on first use.

Notify :: struct {
	checked: bool;
	available: bool;
	authorized: bool; // requested (the reply arrives asynchronously)
}

nt: Notify;

ns_string :: (str: string) -> Id {
	s0 := msg(Id, cls("NSString"), "alloc");
	s1 := msg(Id, s0, "initWithBytes:length:encoding:", raw_data(str), cast(NS.UInteger)(len(str)), cast(NS.UInteger)(4));
	return msg(Id, s1, "autorelease");
}

center :: () -> Id {
	if !nt.checked {
		nt.checked = true;
		bundle := msg(Id, cls("NSBundle"), "mainBundle");
		ident := ifx bundle != null then msg(Id, bundle, "bundleIdentifier") else null;
		nt.available = ident != null && cls("UNUserNotificationCenter") != null;
	}
	if !nt.available { return null; }
	return msg(Id, cls("UNUserNotificationCenter"), "currentNotificationCenter");
}
#scope_export

notify_supported :: () -> bool {return center() != null;}

// notify_show posts a banner (title, body); `id` replaces an earlier one with the same id.
notify_show :: (title: string, body: string, id: string) -> bool {
	c := center();
	if c == null { return false; }
	if !nt.authorized {
		nt.authorized = true;
		// UNAuthorizationOptionBadge | Sound | Alert; completion handler: nil block
		msg(Void, c, "requestAuthorizationWithOptions:completionHandler:", cast(NS.UInteger)(1 | 2 | 4), cast(*void)(null));
	}
	content := objc.new_obj("UNMutableNotificationContent");
	msg(Void, content, "setTitle:", ns_string(title));
	msg(Void, content, "setBody:", ns_string(body));
	req := msg(Id, cls("UNNotificationRequest"), "requestWithIdentifier:content:trigger:", ns_string(id), content, cast(*void)(null));
	msg(Void, c, "addNotificationRequest:withCompletionHandler:", req, cast(*void)(null));
	msg(Void, content, "release");
	return true;
}

// set_badge sets the dock tile badge ("" clears it).
set_badge :: (text: string) {
	app := msg(Id, cls("NSApplication"), "sharedApplication");
	if app == null { return; }
	tile := msg(Id, app, "dockTile");
	if tile == null { return; }
	msg(Void, tile, "setBadgeLabel:", ifx text == "" then cast(Id)(null) else ns_string(text));
}

