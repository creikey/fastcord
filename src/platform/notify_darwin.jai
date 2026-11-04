// OS notifications and the dock badge.
//
// Notifications use UNUserNotificationCenter, which only works for a process with a bundle identifier (an
// .app bundle); an unbundled binary gets no center (the API raises), so notify_show reports false there and
// callers still get the sound and badge. Authorization is requested once, on the first banner or badge: a
// bundled app's Dock badge stays hidden until its notifications are allowed.

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

// Sets the dock tile badge ("" clears it).
set_badge :: (text: string) {
    free(notify.badge);
    notify.badge = copy_string(text);
    if text { c := notification_center(); if c authorize(c); }
    apply_badge();
}

#scope_file

notify: struct {
    checked: bool;
    available: bool;
    authorized: bool; // requested (the reply arrives asynchronously)
    badge: string; // the Dock badge's text, set again once notifications are allowed
};

authorize :: (c: Id) {
    if notify.authorized return;
    notify.authorized = true;
    reply_block = .{isa = cast(*void) _NSConcreteGlobalBlock, flags = BLOCK_IS_GLOBAL, invoke = cast(*void) authorization_reply, descriptor = *block_descriptor};
    // UNAuthorizationOptionBadge | Sound | Alert
    msg(Void, c, "requestAuthorizationWithOptions:completionHandler:", cast(NSUInteger) (1 | 2 | 4), *reply_block);
}

// Runs on a background queue. The Dock may not show a badge set before the user allowed notifications, so
// set it again on the main thread.
authorization_reply :: (b: *Block, granted: bool, error: Id) #c_call {
    if granted dispatch_async_f(*_dispatch_main_q, null, cast(*void) reapply_badge);
}

reapply_badge :: (user: *void) #c_call {
    c := s.ctx; push_context,defer_pop c;
    apply_badge();
}

apply_badge :: () {
    app := msg(Id, cls("NSApplication"), "sharedApplication");
    if !app return;
    tile := msg(Id, app, "dockTile");
    if !tile return;
    msg(Void, tile, "setBadgeLabel:", ifx notify.badge then nsstr(notify.badge) else null);
}

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
// is null, so no banner shows and permission is never asked, which keeps the Dock badge hidden.
user_notifications :: #library,system,link_always "UserNotifications";

libsystem :: #system_library "libSystem";
_NSConcreteGlobalBlock :: () #foreign libsystem;
_dispatch_main_q: u8 #elsewhere libsystem; // dispatch_get_main_queue()
dispatch_async_f :: (queue: *void, ctx: *void, work: *void) #foreign libsystem;
