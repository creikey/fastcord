// Seconds east of UTC for the local timezone at unix time t (its DST rule then).
tz_offset_seconds :: (t: s64) -> s64 {
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
localtime_r :: (t: *s64, out: *Tm) -> *Tm #foreign libc;
