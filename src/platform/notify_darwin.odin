#+build darwin
package platform

import NS "core:sys/darwin/Foundation"
import "fc:platform/objc"

@(require) foreign import "system:UserNotifications.framework"

// OS notifications and the dock badge.
//
// Notifications use UNUserNotificationCenter, which only works for a process
// with a bundle identifier (an .app bundle); an unbundled binary gets no
// center (the API raises), so notify_show reports false there and callers
// still get the sound and badge. Authorization is requested once, on first use.

@(private = "file")
Notify :: struct {
	checked:    bool,
	available:  bool,
	authorized: bool, // requested (the reply arrives asynchronously)
}

@(private = "file")
nt: Notify

@(private = "file")
ns_string :: proc(str: string) -> Id {
	s0 := msg(Id, cls("NSString"), "alloc")
	s1 := msg(Id, s0, "initWithBytes:length:encoding:", raw_data(str), NS.UInteger(len(str)), NS.UInteger(4))
	return msg(Id, s1, "autorelease")
}

@(private = "file")
center :: proc() -> Id {
	if !nt.checked {
		nt.checked = true
		bundle := msg(Id, cls("NSBundle"), "mainBundle")
		ident := bundle != nil ? msg(Id, bundle, "bundleIdentifier") : nil
		nt.available = ident != nil && cls("UNUserNotificationCenter") != nil
	}
	if !nt.available do return nil
	return msg(Id, cls("UNUserNotificationCenter"), "currentNotificationCenter")
}

notify_supported :: proc() -> bool {return center() != nil}

// notify_show posts a banner (title, body); `id` replaces an earlier one with the same id.
notify_show :: proc(title, body, id: string) -> bool {
	c := center()
	if c == nil do return false
	if !nt.authorized {
		nt.authorized = true
		// UNAuthorizationOptionBadge | Sound | Alert; completion handler: nil block
		msg(Void, c, "requestAuthorizationWithOptions:completionHandler:", NS.UInteger(1 | 2 | 4), rawptr(nil))
	}
	content := objc.new_obj("UNMutableNotificationContent")
	msg(Void, content, "setTitle:", ns_string(title))
	msg(Void, content, "setBody:", ns_string(body))
	req := msg(Id, cls("UNNotificationRequest"), "requestWithIdentifier:content:trigger:", ns_string(id), content, rawptr(nil))
	msg(Void, c, "addNotificationRequest:withCompletionHandler:", req, rawptr(nil))
	msg(Void, content, "release")
	return true
}

// set_badge sets the dock tile badge ("" clears it).
set_badge :: proc(text: string) {
	app := msg(Id, cls("NSApplication"), "sharedApplication")
	if app == nil do return
	tile := msg(Id, app, "dockTile")
	if tile == nil do return
	msg(Void, tile, "setBadgeLabel:", text == "" ? Id(nil) : ns_string(text))
}
