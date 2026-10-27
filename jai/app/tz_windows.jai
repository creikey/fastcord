	GetTimeZoneInformation :: (lpTimeZoneInformation: *win.TIME_ZONE_INFORMATION) -> win.DWORD #foreign kernel32;

// Seconds east of UTC for the local timezone, now.
tz_offset_seconds :: () -> s64 {
	// Like libc on macOS, honor TZ=UTC (the UI tests pin it); other TZ values are left to Windows.
	if os.get_env("TZ", temp) == {
	case "UTC"; #through; case "UTC0"; #through; case "GMT"; #through; case "GMT0";
		return 0;
	}
	tzi: win.TIME_ZONE_INFORMATION;
	r := GetTimeZoneInformation(*tzi);
	bias := cast(s64)(tzi.Bias);
	if r == 2 { bias += cast(s64)(tzi.DaylightBias); } // TIME_ZONE_ID_DAYLIGHT
	return -bias * 60;
}

