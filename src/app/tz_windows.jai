// Seconds east of UTC for the local timezone at unix time t (the zone's DST rule for that year).
tz_offset_seconds :: (t: s64) -> s64 {
	// Like libc on macOS, honor TZ=UTC (the UI tests pin it); other TZ values are left to Windows.
	tz := env_var("TZ");
	if tz == "UTC" || tz == "UTC0" || tz == "GMT" || tz == "GMT0" return 0;
	TICKS :: 10_000_000; // FILETIME counts 100 ns since 1601
	ft, lft: Windows.FILETIME;
	ft.QuadPart = cast(u64) ((t + 11_644_473_600) * TICKS);
	utc, local: Windows.SYSTEMTIME;
	if !Windows.FileTimeToSystemTime(*ft, *utc) return 0;
	if !Windows.SystemTimeToTzSpecificLocalTime(null, *utc, *local) return 0;
	if !Windows.SystemTimeToFileTime(*local, *lft) return 0;
	return (cast(s64) lft.QuadPart - cast(s64) ft.QuadPart) / TICKS;
}
