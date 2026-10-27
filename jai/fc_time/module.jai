// Durations, monotonic ticks and civil time in nanoseconds since the Unix epoch.
#import "Basic";
Basic :: #import "Basic";
#import "fc";

Duration :: s64;
Nanosecond :: cast(Duration) 1;
Microsecond :: 1000 * Nanosecond;
Millisecond :: 1000 * Microsecond;
Second :: 1000 * Millisecond;
Minute :: 60 * Second;
Hour :: 60 * Minute;

Tick :: struct { _nsec: s64; }
Time :: struct { _nsec: s64; }
Month :: enum s64 { January :: 1; February; March; April; May; June; July; August; September; October; November; December; }
Weekday :: enum s64 { Sunday; Monday; Tuesday; Wednesday; Thursday; Friday; Saturday; }

tick_now :: () -> Tick { return .{to_nanoseconds(current_time_monotonic())}; }
tick_since :: (t: Tick) -> Duration { return tick_now()._nsec - t._nsec; }
tick_diff :: (a: Tick, b: Tick) -> Duration { return b._nsec - a._nsec; }
tick_add :: (t: Tick, d: Duration) -> Tick { return .{t._nsec + d}; }
duration_seconds :: (d: Duration) -> float64 { return cast(float64) d / 1.0e9; }
duration_milliseconds :: (d: Duration) -> float64 { return cast(float64) d / 1.0e6; }
duration_microseconds :: (d: Duration) -> float64 { return cast(float64) d / 1.0e3; }
sleep :: (d: Duration) { if d > 0 Basic.sleep_milliseconds(cast(s32) ((d + Millisecond - 1) / Millisecond)); }
accurate_sleep :: (d: Duration) {
    end := tick_now()._nsec + d;
    if d > 2 * Millisecond sleep(d - 2 * Millisecond);
    while tick_now()._nsec < end {}
}

now :: () -> Time { return .{to_nanoseconds(current_time_consensus()) - UNIX_FROM_APOLLO_NS}; }
UNIX_FROM_APOLLO_NS :: #run -> s64 {
    c: Calendar_Time;
    c.year = 1970;
    return to_nanoseconds(calendar_to_apollo(c));
};
unix :: (sec: s64, nsec: s64) -> Time { return .{sec * 1_000_000_000 + nsec}; }
since :: (t: Time) -> Duration { return now()._nsec - t._nsec; }
diff :: (a: Time, b: Time) -> Duration { return b._nsec - a._nsec; }
time_add :: (t: Time, d: Duration) -> Time { return .{t._nsec + d}; }
time_to_unix :: (t: Time) -> s64 { return t._nsec / 1_000_000_000; }
time_to_unix_nano :: (t: Time) -> s64 { return t._nsec; }
to_unix_seconds :: time_to_unix;
to_unix_nanoseconds :: time_to_unix_nano;

// Civil-from-days (Howard Hinnant), proleptic Gregorian, UTC.
days_to_civil :: (z0: s64) -> s64, s64, s64 {
    z := z0 + 719468;
    era := (ifx z >= 0 then z else z - 146096) / 146097;
    doe := z - era * 146097;
    yoe := (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    y := yoe + era * 400;
    doy := doe - (365 * yoe + yoe / 4 - yoe / 100);
    mp := (5 * doy + 2) / 153;
    d := doy - (153 * mp + 2) / 5 + 1;
    m := ifx mp < 10 then mp + 3 else mp - 9;
    return ifx m <= 2 then y + 1 else y, m, d;
}
days_from_civil :: (y0: s64, m: s64, d: s64) -> s64 {
    y := ifx m <= 2 then y0 - 1 else y0;
    era := (ifx y >= 0 then y else y - 399) / 400;
    yoe := y - era * 400;
    doy := (153 * (ifx m > 2 then m - 3 else m + 9) + 2) / 5 + d - 1;
    doe := yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return era * 146097 + doe - 719468;
}
floor_div :: (a: s64, b: s64) -> s64 { q := a / b; if (a % b != 0) && ((a < 0) != (b < 0)) q -= 1; return q; }
date :: (t: Time) -> int, Month, int {
    y, m, d := days_to_civil(floor_div(t._nsec, 86400 * 1_000_000_000));
    return y, cast(Month) m, d;
}
clock_from_time :: (t: Time) -> int, int, int {
    s := floor_div(t._nsec, 1_000_000_000);
    sod := s - floor_div(s, 86400) * 86400;
    return sod / 3600, (sod / 60) % 60, sod % 60;
}
weekday :: (t: Time) -> Weekday {
    days := floor_div(t._nsec, 86400 * 1_000_000_000);
    return cast(Weekday) ((days % 7 + 11) % 7);
}
components_to_time :: (y: int, m: int, d: int, hh: int, mm: int, ss: int, ns := 0) -> Time, bool {
    if m < 1 || m > 12 || d < 1 || d > 31 || hh < 0 || hh > 23 || mm < 0 || mm > 59 || ss < 0 || ss > 60 return .{}, false;
    days := days_from_civil(y, m, d);
    return .{((days * 86400 + hh * 3600 + mm * 60 + ss) * 1_000_000_000) + ns}, true;
}

// "2024-05-01T12:34:56.789+00:00": returns the time, the UTC offset in minutes, and bytes consumed.
iso8601_to_time_and_offset :: (s: string) -> Time, int, int {
    num :: (s: string, i: *int, n: int) -> int, bool {
        v := 0;
        for 1..n {
            if i.* >= s.count || s[i.*] < #char "0" || s[i.*] > #char "9" return 0, false;
            v = v * 10 + s[i.*] - #char "0"; i.* += 1;
        }
        return v, true;
    }
    i := 0;
    y, ok1 := num(s, *i, 4); if !ok1 || i >= s.count || s[i] != #char "-" return .{}, 0, 0; i += 1;
    mo, ok2 := num(s, *i, 2); if !ok2 || i >= s.count || s[i] != #char "-" return .{}, 0, 0; i += 1;
    d, ok3 := num(s, *i, 2); if !ok3 || i >= s.count || (s[i] != #char "T" && s[i] != #char " " && s[i] != #char "t") return .{}, 0, 0; i += 1;
    hh, ok4 := num(s, *i, 2); if !ok4 || i >= s.count || s[i] != #char ":" return .{}, 0, 0; i += 1;
    mm, ok5 := num(s, *i, 2); if !ok5 || i >= s.count || s[i] != #char ":" return .{}, 0, 0; i += 1;
    ss, ok6 := num(s, *i, 2); if !ok6 return .{}, 0, 0;
    ns := 0;
    if i < s.count && s[i] == #char "." {
        i += 1;
        scale := 100_000_000;
        while i < s.count && s[i] >= #char "0" && s[i] <= #char "9" { ns += (s[i] - #char "0") * scale; scale /= 10; i += 1; }
    }
    off := 0;
    if i < s.count && (s[i] == #char "Z" || s[i] == #char "z") i += 1;
    else if i < s.count && (s[i] == #char "+" || s[i] == #char "-") {
        sign := ifx s[i] == #char "-" then -1 else 1; i += 1;
        oh, okh := num(s, *i, 2); if !okh return .{}, 0, 0;
        if i < s.count && s[i] == #char ":" i += 1;
        om, okm := num(s, *i, 2); if !okm return .{}, 0, 0;
        off = sign * (oh * 60 + om);
    } else return .{}, 0, 0;
    t, ok := components_to_time(y, mo, d, hh, mm, ss, ns);
    if !ok return .{}, 0, 0;
    t._nsec -= off * 60 * 1_000_000_000;
    return t, off, i;
}
rfc3339_to_time_utc :: (s: string) -> Time, int {
    t, _, n := iso8601_to_time_and_offset(s);
    return t, n;
}
time_to_rfc3339 :: (t: Time, utc_offset := 0, include_nanos := true, allocator := context.allocator) -> string, bool {
    y, m, d := date(t);
    hh, mm, ss := clock_from_time(t);
    push_allocator(allocator);
    ns := t._nsec - floor_div(t._nsec, 1_000_000_000) * 1_000_000_000;
    frac := ifx include_nanos && ns then tprint(".%", formatInt(ns, minimum_digits = 9)) else "";
    return sprint("%-%-%T%:%:%Z", formatInt(y, minimum_digits = 4), formatInt(cast(int) m, minimum_digits = 2), formatInt(d, minimum_digits = 2),
        formatInt(hh, minimum_digits = 2), formatInt(mm, minimum_digits = 2), formatInt(ss, minimum_digits = 2), frac), true;
}
