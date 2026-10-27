// Windows toast notifications and taskbar overlay badge: not implemented yet
// (needs an AppUserModelID + WinRT ToastNotificationManager). The app still
// plays the notification sound.

notify_supported :: () -> bool {return false;}

notify_show :: (title: string, body: string, id: string) -> bool {return false;}

set_badge :: (text: string) {}

