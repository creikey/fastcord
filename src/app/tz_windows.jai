// Seconds east of UTC for the local timezone, now.
tz_offset_seconds :: () -> s64 {
	// Like libc on macOS, honor TZ=UTC (the UI tests pin it); other TZ values are left to Windows.
	tz := env_var("TZ");
	if tz == "UTC" || tz == "UTC0" || tz == "GMT" || tz == "GMT0" return 0;
	tzi: TIME_ZONE_INFORMATION;
	r := GetTimeZoneInformation(*tzi);
	bias := cast(s64) tzi.Bias;
	if r == 2 bias += tzi.DaylightBias; // TIME_ZONE_ID_DAYLIGHT
	return -bias * 60;
}

#scope_file

// Jai's Windows module declares neither (its TIME_ZONE_INFORMATION is an empty placeholder).
TIME_ZONE_INFORMATION :: struct {
	Bias: s32;
	StandardName: [32]u16;
	StandardDate: Windows.SYSTEMTIME;
	StandardBias: s32;
	DaylightName: [32]u16;
	DaylightDate: Windows.SYSTEMTIME;
	DaylightBias: s32;
}
GetTimeZoneInformation :: (tzi: *TIME_ZONE_INFORMATION) -> u32 #foreign kernel32;
