// OS notifications and the dock badge.
//
// Notifications use UNUserNotificationCenter, which only works for a process with a bundle identifier (an
// .app bundle); an unbundled binary gets no center (the API raises), so notify_show reports false there and
// callers still get the sound and badge. Authorization is requested once, on the first banner.

// Posts a banner (title, body); `id` replaces an earlier one with the same id.
notify_show :: (title: string, body: string, id: string) -> bool {
    c := notification_center();
    if !c return false;
    authorize(c);
    content := objc.new_obj("UNMutableNotificationContent");
    msg(Void, content, "setTitle:", nsstr(title));
    msg(Void, content, "setBody:", nsstr(body));
    req := msg(Id, cls("UNNotificationRequest"), "requestWithIdentifier:content:trigger:", nsstr(id), content, cast(Id) null);
    msg(Void, c, "addNotificationRequest:withCompletionHandler:", req, cast(Id) null);
    msg(Void, content, "release");
    return true;
}

// Draws the badge ("" clears it) onto the Dock icon. Not NSDockTile's badgeLabel: the Dock shows that only
// for an .app whose notifications were allowed with badges on, which a dev build's bare binary never is.
set_badge :: (text: string) {
    app := msg(Id, cls("NSApplication"), "sharedApplication");
    if !app return;
    if !notify.icon notify.icon = msg(Id, msg(Id, app, "applicationIconImage"), "retain"); // before any badge
    if !text { msg(Void, app, "setApplicationIconImage:", notify.icon); return; }
    S :: cast(NSFloat) 256;
    img := msg(Id, msg(Id, cls("NSImage"), "alloc"), "initWithSize:", NSSize.{S, S});
    defer msg(Void, img, "release");
    msg(Void, img, "lockFocus");
    msg(Void, notify.icon, "drawInRect:", NSRect.{.{0, 0}, .{S, S}});
    // A red pill in the top right with the count in white, like the Dock's own badge.
    keys := Id.[nsstr("NSFont"), nsstr("NSColor")]; // NSFontAttributeName, NSForegroundColorAttributeName
    values := Id.[msg(Id, cls("NSFont"), "boldSystemFontOfSize:", S * 0.27), msg(Id, cls("NSColor"), "whiteColor")];
    attrs := msg(Id, cls("NSDictionary"), "dictionaryWithObjects:forKeys:count:", values.data, keys.data, cast(NSUInteger) 2);
    label := nsstr(text);
    size := msg(NSSize, label, "sizeWithAttributes:", attrs);
    h := S * 0.4;
    w := min(max(h, size.width + h * 0.5), S);
    msg(Void, msg(Id, cls("NSColor"), "systemRedColor"), "setFill");
    msg(Void, msg(Id, cls("NSBezierPath"), "bezierPathWithRoundedRect:xRadius:yRadius:", NSRect.{.{S - w, S - h}, .{w, h}}, h / 2, h / 2), "fill");
    msg(Void, label, "drawAtPoint:withAttributes:", NSPoint.{S - (w + size.width) / 2, S - (h + size.height) / 2}, attrs);
    msg(Void, img, "unlockFocus");
    msg(Void, app, "setApplicationIconImage:", img);
}

#scope_file

notify: struct {
    checked: bool;
    available: bool;
    authorized: bool; // requested (the reply arrives asynchronously)
    icon: Id; // the Dock icon without a badge
};

authorize :: (c: Id) {
    if notify.authorized return;
    notify.authorized = true;
    reply_block = .{isa = cast(*void) _NSConcreteGlobalBlock, flags = BLOCK_IS_GLOBAL, invoke = cast(*void) authorization_reply, descriptor = *block_descriptor};
    // UNAuthorizationOptionBadge | Sound | Alert
    msg(Void, c, "requestAuthorizationWithOptions:completionHandler:", cast(NSUInteger) (1 | 2 | 4), *reply_block);
}

authorization_reply :: (b: *Block, granted: bool, error: Id) #c_call {} // on a background queue

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
    if done { (cast(#type (b: *Block) #c_call) done.invoke)(done); } // the completion handler must run
}

// A block literal (clang's Block ABI). BLOCK_IS_GLOBAL makes Block_copy and Block_release no-ops.
Block :: struct { isa: *void; flags, reserved: s32; invoke: *void; descriptor: *Block_Descriptor; }
Block_Descriptor :: struct { reserved, size: u64; }
block_descriptor := Block_Descriptor.{0, size_of(Block)};
BLOCK_IS_GLOBAL :: 1 << 28;
reply_block: Block; // void(^)(BOOL granted, NSError *error)

// Linked for its classes alone: nothing else loads UserNotifications, and without it cls("UNUserNotificationCenter")
// is null, so no banner shows and permission is never asked.
user_notifications :: #library,system,link_always "UserNotifications";

libsystem :: #system_library "libSystem";
_NSConcreteGlobalBlock :: () #foreign libsystem;
