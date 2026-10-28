// zig's macOS headers have no frameworks. rtc_base/logging.cc uses this one only to read a logToStdErr
// preference in release builds; without a bundle id it keeps its default, which is all fastcord needs.
#pragma once
typedef const void *CFStringRef;
typedef unsigned char Boolean;
#define CFBundleGetMainBundle() 0
#define CFBundleGetIdentifier(bundle) ((CFStringRef) 0)
#define CFPreferencesGetAppBooleanValue(key, domain, valid) 0
#define CFSTR(s) ((CFStringRef) 0)
