package app

import win "core:sys/windows"

// Seconds east of UTC for the local timezone, now.
tz_offset_seconds :: proc() -> i64 {
	tzi: win.TIME_ZONE_INFORMATION
	r := win.GetTimeZoneInformation(&tzi)
	bias := i64(tzi.Bias)
	if r == 2 do bias += i64(tzi.DaylightBias) // TIME_ZONE_ID_DAYLIGHT
	return -bias * 60
}
