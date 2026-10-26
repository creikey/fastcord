package app

import "core:os"
import win "core:sys/windows"

foreign import kernel32 "system:Kernel32.lib"

@(default_calling_convention = "system")
foreign kernel32 {
	GetTimeZoneInformation :: proc(lpTimeZoneInformation: ^win.TIME_ZONE_INFORMATION) -> win.DWORD ---
}

// Seconds east of UTC for the local timezone, now.
tz_offset_seconds :: proc() -> i64 {
	// Like libc on macOS, honor TZ=UTC (the UI tests pin it); other TZ values are left to Windows.
	switch os.get_env("TZ", context.temp_allocator) {
	case "UTC", "UTC0", "GMT", "GMT0":
		return 0
	}
	tzi: win.TIME_ZONE_INFORMATION
	r := GetTimeZoneInformation(&tzi)
	bias := i64(tzi.Bias)
	if r == 2 do bias += i64(tzi.DaylightBias) // TIME_ZONE_ID_DAYLIGHT
	return -bias * 60
}
