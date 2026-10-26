#+build windows
package platform

// Windows toast notifications and taskbar overlay badge: not implemented yet
// (needs an AppUserModelID + WinRT ToastNotificationManager). The app still
// plays the notification sound.

notify_supported :: proc() -> bool {return false}

notify_show :: proc(title, body, id: string) -> bool {return false}

set_badge :: proc(text: string) {}
