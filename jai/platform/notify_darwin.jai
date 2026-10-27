// OS notifications and the dock badge.
//
// Notifications use UNUserNotificationCenter, which only works for a process with a bundle identifier (an
// .app bundle); an unbundled binary gets no center (the API raises), so notify_show reports false there and
// callers still get the sound and badge. Authorization is requested once, on first use.

// Posts a banner (title, body); `id` replaces an earlier one with the same id.
notify_show :: (title: string, body: string, id: string) -> bool {
    c := notification_center();
    if !c return false;
    if !notify.authorized {
        notify.authorized = true;
        // UNAuthorizationOptionBadge | Sound | Alert; completion handler: nil block
        msg(Void, c, "requestAuthorizationWithOptions:completionHandler:", cast(NSUInteger) (1 | 2 | 4), cast(Id) null);
    }
    content := objc.new_obj("UNMutableNotificationContent");
    msg(Void, content, "setTitle:", nsstr(title));
    msg(Void, content, "setBody:", nsstr(body));
    req := msg(Id, cls("UNNotificationRequest"), "requestWithIdentifier:content:trigger:", nsstr(id), content, cast(Id) null);
    msg(Void, c, "addNotificationRequest:withCompletionHandler:", req, cast(Id) null);
    msg(Void, content, "release");
    return true;
}

// Sets the dock tile badge ("" clears it).
set_badge :: (text: string) {
    app := msg(Id, cls("NSApplication"), "sharedApplication");
    if !app return;
    tile := msg(Id, app, "dockTile");
    if !tile return;
    msg(Void, tile, "setBadgeLabel:", ifx text then nsstr(text) else null);
}

#scope_file

notify: struct {
    checked: bool;
    available: bool;
    authorized: bool; // requested (the reply arrives asynchronously)
};

notification_center :: () -> Id {
    if !notify.checked {
        notify.checked = true;
        bundle := msg(Id, cls("NSBundle"), "mainBundle");
        ident := ifx bundle then msg(Id, bundle, "bundleIdentifier") else null;
        notify.available = ident != null && cls("UNUserNotificationCenter") != null;
    }
    if !notify.available return null;
    return msg(Id, cls("UNUserNotificationCenter"), "currentNotificationCenter");
}
