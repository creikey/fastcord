package app

foreign import libc "system:c"

@(private = "file")
Tm :: struct {
	sec, min, hour, mday, mon, year, wday, yday, isdst: i32,
	gmtoff:                                              i64,
	zone:                                                cstring,
}

@(private = "file", default_calling_convention = "c")
foreign libc {
	time :: proc(t: ^i64) -> i64 ---
	localtime_r :: proc(t: ^i64, out: ^Tm) -> ^Tm ---
}

// Seconds east of UTC for the local timezone, now.
tz_offset_seconds :: proc() -> i64 {
	t := time(nil)
	tm: Tm
	localtime_r(&t, &tm)
	return tm.gmtoff
}
