// Seconds east of UTC for the local timezone, now.
tz_offset_seconds :: () -> s64 {
	t := c_time(null);
	tm: Tm;
	localtime_r(*t, *tm);
	return tm.gmtoff;
}

#scope_file

Tm :: struct {
	sec, min, hour, mday, mon, year, wday, yday, isdst: s32;
	gmtoff: s64;
	zone: *u8;
}
c_time :: (t: *s64) -> s64 #foreign libc "time";
localtime_r :: (t: *s64, out: *Tm) -> *Tm #foreign libc;
