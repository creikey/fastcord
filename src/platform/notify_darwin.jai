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
        if notify.available {
            // A delegate, so a click reports the notification's id (Notification_Click).
            d := objc.allocate_class(cls("NSObject"), "FCNotificationDelegate");
            objc.add_method(d, "userNotificationCenter:didReceiveNotificationResponse:withCompletionHandler:", cast(*void) notification_clicked, "v@:@@@");
            objc.register_class(d);
            msg(Void, msg(Id, cls("UNUserNotificationCenter"), "currentNotificationCenter"), "setDelegate:", objc.new_obj("FCNotificationDelegate"));
        }
    }
    if !notify.available return null;
    return msg(Id, cls("UNUserNotificationCenter"), "currentNotificationCenter");
}

notification_clicked :: (self: Id, cmd: SEL, center: Id, response: Id, done: *Block) #c_call {
    c := s.ctx; push_context,defer_pop c;
    id := msg(Id, msg(Id, msg(Id, response, "notification"), "request"), "identifier");
    push_event(.{kind = .Notification_Click, text = to_jai_string(id, temp), time = time_now()});
    request_frame();
    if done done.invoke(done); // the completion handler must run
}

Block :: struct { isa: *void; flags, reserved: s32; invoke: (b: *Block) #c_call; } // a void(^)(void) block
