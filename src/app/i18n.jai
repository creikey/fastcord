// Localisation. UI text is English in the source, wrapped where it is shown: L("Save"), or
// Lp("% member", "% members", n) for a count. lang/keys.txt (sorted, written by `tools/i18n.py extract`)
// is read at compile time, so each call compiles to an index into the current language's table: no
// hashing per frame. lang/<code>.txt holds "English<TAB>translation" lines, read once when the language
// changes; a missing line shows the English. A plural's translation lists the language's CLDR forms
// (plural_index) separated by "|". "##id" suffixes (widget ids) are kept and never translated.
// Arguments can be reordered with %1, %2 (Basic's print). Right-to-left scripts are not supported.

// L: the current language's text for the literal s.
L :: inline ($s: string) -> string {
	I :: #run key_index(s);
	#if I >= 0 if i18n.table.count && i18n.table[I] return i18n.table[I];
	return s;
}

// Lp: the form of one/other (English singular and plural) for n, still to be formatted.
Lp :: inline ($one: string, $other: string, n: s64) -> string {
	I :: #run key_index(tprint("%|%", one, other));
	#if I >= 0 if i18n.table.count && i18n.table[I] return plural_form(i18n.table[I], n);
	return ifx n == 1 then one else other;
}

// tr: L for a string known only at run time (a table's names); a binary search, so not for long lists.
tr :: (s: string) -> string {
	i := key_index(s);
	return ifx i >= 0 && i18n.table.count && i18n.table[i] then i18n.table[i] else s;
}

// The UI language: the synced setting, else the system's (identity.jai discord_locale).
ui_locale :: () -> string {
	st := store().settings.locale;
	if st return st;
	return ifx app.client then app.client.id.platform.locale else "en-US";
}

// Once per frame: load the table when the language changed.
i18n_frame :: () {
	code := ui_locale();
	if code == i18n.code && i18n.table.count return;
	reset(*i18n.pool);
	push_allocator(dc.pool_allocator(*i18n.pool));
	i18n.code = copy_string(code);
	i18n.table = NewArray(KEYS.count, string);
	i18n.fmt = *LOCALE_FORMATS[0];
	for * LOCALE_FORMATS if it.code == code i18n.fmt = it;
	i18n.rule = plural_rule(code);
	data := "";
	file := ifx code == "es-419" then "es-ES" else code; // one Spanish for both
	for LANG_FILES if it.code == file data = it.text;
	if !data return;
	found: Table(string, string);
	found.allocator = temp;
	for line: split(data, "\n",, temp) {
		if !line || line[0] == #char "#" continue;
		tab := find_index_from_left(line, #char "\t");
		if tab <= 0 continue;
		table_set(*found, slice(line, 0, tab), slice(line, tab + 1, line.count - tab - 1));
	}
	for KEYS {
		cut := find_index_from_left(it, "##");
		visible := ifx cut >= 0 then slice(it, 0, cut) else it;
		ok, t := table_find(*found, escape_key(visible));
		if ok && t i18n.table[it_index] = join(unescape(t), ifx cut >= 0 then slice(it, cut, it.count - cut) else "");
	}
}

// ---- dates and numbers ----

// A date pattern: {d} {dd} day, {m} {mm} month number, {month} {mon} its name (full, short), {y} year,
// {weekday} {wkd} the day's name, {date} the long date, {time} the clock.
Locale_Formats :: struct {
	code: string;
	numeric: string;  // 10/24/2026 (moment's L)
	dm: string;       // October 24 (the long date without its year)
	long: string;     // October 24, 2026 (LL); with {mon} for {month}: Oct 24, 2026 (ll)
	full: string;     // Tuesday, October 27, 2026 3:04 PM (LLLL)
	my: string;       // Oct 2026
	h12: bool;        // the language's own clock (Time format: Auto)
	clock12 := "{h}:{min}{sp}{ampm}";
	tsep := ":";      // between hours, minutes and seconds
	group := ",";     // thousands
	group_min := 4;   // the fewest digits that get grouped (es and pl leave 1000 alone)
}

// CLDR's patterns as Intl and moment format them for the client's languages.
LOCALE_FORMATS := Locale_Formats.[
	.{code = "en-US", numeric = "{m}/{d}/{y}", dm = "{month} {d}", long = "{month} {d}, {y}", full = "{weekday}, {date} {time}", my = "{mon} {y}", h12 = true},
	.{code = "en-GB", numeric = "{dd}/{mm}/{y}", dm = "{d} {month}", long = "{d} {month} {y}", full = "{weekday}, {date} {time}", my = "{mon} {y}"},
	.{code = "zh-CN", numeric = "{y}/{mm}/{dd}", dm = "{m}月{d}日", long = "{y}年{m}月{d}日", full = "{date}{weekday} {time}", my = "{y}年{m}月", clock12 = "{ampm}{h}:{min}"},
	.{code = "zh-TW", numeric = "{y}/{mm}/{dd}", dm = "{m}月{d}日", long = "{y}年{m}月{d}日", full = "{date}{weekday} {time}", my = "{y}年{m}月", h12 = true, clock12 = "{ampm}{h}:{min}"},
	.{code = "cs", numeric = "{d}. {m}. {y}", dm = "{d}. {month}", long = "{d}. {month} {y}", full = "{weekday} {date} {time}", my = "{mon} {y}", group = " "},
	.{code = "da", numeric = "{dd}.{mm}.{y}", dm = "{d}. {month}", long = "{d}. {month} {y}", full = "{weekday} d. {date} {time}", my = "{mon} {y}", tsep = ".", group = "."},
	.{code = "nl", numeric = "{dd}-{mm}-{y}", dm = "{d} {month}", long = "{d} {month} {y}", full = "{weekday} {date} {time}", my = "{mon} {y}", group = "."},
	.{code = "fr", numeric = "{dd}/{mm}/{y}", dm = "{d} {month}", long = "{d} {month} {y}", full = "{weekday} {date} {time}", my = "{mon} {y}", group = " "},
	.{code = "de", numeric = "{dd}.{mm}.{y}", dm = "{d}. {month}", long = "{d}. {month} {y}", full = "{weekday}, {date} {time}", my = "{mon} {y}", group = "."},
	.{code = "el", numeric = "{d}/{m}/{y}", dm = "{d} {month}", long = "{d} {month} {y}", full = "{weekday}, {date} {time}", my = "{mon} {y}", h12 = true, group = "."},
	.{code = "hu", numeric = "{y}. {mm}. {dd}.", dm = "{month} {d}.", long = "{y}. {month} {d}.", full = "{date}, {weekday} {time}", my = "{y}. {mon}", group = " "},
	.{code = "it", numeric = "{dd}/{mm}/{y}", dm = "{d} {month}", long = "{d} {month} {y}", full = "{weekday} {date} {time}", my = "{mon} {y}", group = "."},
	.{code = "ja", numeric = "{y}/{mm}/{dd}", dm = "{m}月{d}日", long = "{y}年{m}月{d}日", full = "{date} {weekday} {time}", my = "{y}年{m}月", clock12 = "{ampm}{h}:{min}"},
	.{code = "ko", numeric = "{y}. {mm}. {dd}.", dm = "{m}월 {d}일", long = "{y}년 {m}월 {d}일", full = "{date} {weekday} {time}", my = "{y}년 {m}월", h12 = true, clock12 = "{ampm} {h}:{min}"},
	.{code = "pl", numeric = "{dd}.{mm}.{y}", dm = "{d} {month}", long = "{d} {month} {y}", full = "{weekday}, {date} {time}", my = "{mon} {y}", group = " ", group_min = 5},
	.{code = "pt-BR", numeric = "{dd}/{mm}/{y}", dm = "{d} de {month}", long = "{d} de {month} de {y}", full = "{weekday}, {date} {time}", my = "{mon} de {y}", group = "."},
	.{code = "ru", numeric = "{dd}.{mm}.{y}", dm = "{d} {month}", long = "{d} {month} {y} г.", full = "{weekday}, {date}, {time}", my = "{mon} {y} г.", group = " "},
	.{code = "es-419", numeric = "{d}/{m}/{y}", dm = "{d} de {month}", long = "{d} de {month} de {y}", full = "{weekday}, {date} {time}", my = "{mon} {y}", h12 = true, group_min = 5},
	.{code = "es-ES", numeric = "{d}/{m}/{y}", dm = "{d} de {month}", long = "{d} de {month} de {y}", full = "{weekday}, {date} {time}", my = "{mon} {y}", group = ".", group_min = 5},
	.{code = "sv-SE", numeric = "{y}-{mm}-{dd}", dm = "{d} {month}", long = "{d} {month} {y}", full = "{weekday} {date} {time}", my = "{mon} {y}", group = " "},
	.{code = "tr", numeric = "{dd}.{mm}.{y}", dm = "{d} {month}", long = "{d} {month} {y}", full = "{date} {weekday} {time}", my = "{mon} {y}", group = "."},
	.{code = "bg", numeric = "{d}.{mm}.{y} г.", dm = "{d} {month}", long = "{d} {month} {y} г.", full = "{weekday}, {date}, {time}", my = "{mon} {y} г.", group = " "},
	.{code = "uk", numeric = "{dd}.{mm}.{y}", dm = "{d} {month}", long = "{d} {month} {y} р.", full = "{weekday}, {date}, {time}", my = "{mon} {y} р.", group = " "},
	.{code = "fi", numeric = "{d}.{m}.{y}", dm = "{d}. {month}", long = "{d}. {month} {y}", full = "{weekday} {date} klo {time}", my = "{mon} {y}", tsep = ".", group = " "},
	.{code = "no", numeric = "{dd}.{mm}.{y}", dm = "{d}. {month}", long = "{d}. {month} {y}", full = "{weekday} {date} {time}", my = "{mon} {y}", group = " "},
	.{code = "hr", numeric = "{dd}. {mm}. {y}.", dm = "{d}. {month}", long = "{d}. {month} {y}.", full = "{weekday}, {date} {time}", my = "{mon} {y}.", group = "."},
	.{code = "ro", numeric = "{dd}.{mm}.{y}", dm = "{d} {month}", long = "{d} {month} {y}", full = "{weekday}, {date} {time}", my = "{mon} {y}", group = "."},
	.{code = "lt", numeric = "{y}-{mm}-{dd}", dm = "{month} {d} d.", long = "{y} m. {month} {d} d.", full = "{date}, {weekday} {time}", my = "{y} m. {mon}", group = " "},
	.{code = "th", numeric = "{d}/{m}/{y}", dm = "{d} {month}", long = "{d} {month} {y}", full = "{weekday}ที่ {date} {time}", my = "{mon} {y}"},
	.{code = "vi", numeric = "{dd}/{mm}/{y}", dm = "{d} {month}", long = "{d} {month}, {y}", full = "{weekday}, {date} {time}", my = "{mon} {y}", group = "."},
	.{code = "hi", numeric = "{d}/{m}/{y}", dm = "{d} {month}", long = "{d} {month} {y}", full = "{weekday}, {date} {time}", my = "{mon} {y}", h12 = true},
];

month_name :: (m0: int, short := false) -> string {
	names := ifx short then L("Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec") else L("January|February|March|April|May|June|July|August|September|October|November|December");
	return list_item(names, m0);
}

weekday_name :: (d0: int, short := false) -> string {
	names := ifx short then L("Sun|Mon|Tue|Wed|Thu|Fri|Sat") else L("Sunday|Monday|Tuesday|Wednesday|Thursday|Friday|Saturday");
	return list_item(names, d0);
}

// date_format: t in one of the language's patterns (Locale_Formats).
date_format :: (pattern: string, t: Calendar_Time, clock := "", depth := 0) -> string {
	assert(depth < 2); // {date} is the long pattern, which has none
	sb: String_Builder;
	sb.allocator = temp;
	p := pattern;
	while p {
		if p[0] != #char "{" { append(*sb, p[0]); advance(*p); continue; }
		end := find_index_from_left(p, #char "}");
		if end < 0 { append(*sb, p); break; }
		tok := slice(p, 1, end - 1);
		advance(*p, end + 1);
		if tok == {
			case "d"; print_to_builder(*sb, "%", t.day_of_month_starting_at_0 + 1);
			case "dd"; print_to_builder(*sb, "%", formatInt(t.day_of_month_starting_at_0 + 1, minimum_digits = 2));
			case "m"; print_to_builder(*sb, "%", t.month_starting_at_0 + 1);
			case "mm"; print_to_builder(*sb, "%", formatInt(t.month_starting_at_0 + 1, minimum_digits = 2));
			case "y"; print_to_builder(*sb, "%", t.year);
			case "month"; append(*sb, month_name(t.month_starting_at_0));
			case "mon"; append(*sb, month_name(t.month_starting_at_0, short = true));
			case "weekday"; append(*sb, weekday_name(t.day_of_week_starting_at_0));
			case "wkd"; append(*sb, weekday_name(t.day_of_week_starting_at_0, short = true));
			case "date"; append(*sb, date_format(i18n_fmt().long, t, depth = depth + 1));
			case "time"; append(*sb, clock);
		}
	}
	return builder_to_string(*sb,, temp);
}

// "Oct 24, 2026" (ll): the long date with short month names.
date_medium :: (t: Calendar_Time) -> string { return date_format(replace(i18n_fmt().long, "{month}", "{mon}",, temp), t); }

// "10/24": the numeric date without its year.
date_numeric_short :: (t: Calendar_Time) -> string {
	p := i18n_fmt().numeric;
	y := find_index_from_left(p, "{y}");
	if y == 0 {
		p = slice(p, 3, p.count - 3);
		while p && p[0] != #char "{" advance(*p);
	} else if y > 0 {
		p = slice(p, 0, find_index_from_right(slice(p, 0, y), #char "}") + 1);
	}
	return date_format(p, t);
}

// "3:04 PM", or "15:04" on a 24-hour clock; sep goes between the time and AM/PM.
clock_text :: (t: Calendar_Time, seconds := false, sep := " ") -> string {
	f := i18n_fmt();
	m := tprint("%", formatInt(t.minute, minimum_digits = 2));
	if seconds m = tprint("%1%2%3", m, f.tsep, formatInt(t.second, minimum_digits = 2));
	if use_24h() return tprint("%1%2%3", formatInt(t.hour, minimum_digits = 2), f.tsep, m);
	h := t.hour % 12;
	out := replace(f.clock12, "{h}", tprint("%", ifx h then h else 12),, temp);
	out = replace(out, ":{min}", tprint("%1%2", f.tsep, m),, temp);
	out = replace(out, "{sp}", sep,, temp);
	return replace(out, "{ampm}", ifx t.hour >= 12 then L("PM") else L("AM"),, temp);
}

// use_24h: the Time format setting; Auto follows the language's own clock, as Intl does.
use_24h :: () -> bool {
	st := *store().settings;
	if st.hour_cycle != .Auto return st.hour_cycle == .H23;
	return !i18n_fmt().h12;
}

i18n_fmt :: () -> *Locale_Formats { return ifx i18n.fmt then i18n.fmt else *LOCALE_FORMATS[0]; } // set from the first frame

// "1,234" with the language's digit grouping.
num_text :: (n: s64) -> string {
	s := tprint("%", abs(n));
	if s.count < i18n_fmt().group_min return ifx n < 0 then tprint("-%", s) else s;
	sb: String_Builder;
	sb.allocator = temp;
	if n < 0 append(*sb, "-");
	for 0..s.count - 1 {
		if it && (s.count - it) % 3 == 0 append(*sb, i18n_fmt().group);
		append(*sb, s[it]);
	}
	return builder_to_string(*sb,, temp);
}

#scope_file

i18n: struct {
	code: string;
	table: []string; // KEYS' translations, "" where missing
	fmt: *Locale_Formats;
	rule: Plural_Rule;
	pool: Flat_Pool;
};

// CLDR plural categories for whole numbers, in the order a translation lists its forms.
Plural_Rule :: enum u8 {
	One_Other;      // n = 1
	Zero_One_Other; // n = 0 or 1 (fr, pt, hi)
	Other;          // one form (ja, zh, ko, th, vi)
	One_Few_Many;   // ru, uk, hr: 1, 21, 31 | 2-4, 22-24 | the rest
	Polish;         // 1 | 2-4, 22-24 | the rest
	Czech;          // 1 | 2-4 | the rest
	Lithuanian;     // 1, 21 | 2-9, 22-29 | 11-19, 10, 20
	Romanian;       // 1 | 0, 2-19, 102-119 | the rest
}

plural_rule :: (code: string) -> Plural_Rule {
	if code == {
		case "fr"; #through; case "pt-BR"; #through; case "hi"; return .Zero_One_Other;
		case "ja"; #through; case "zh-CN"; #through; case "zh-TW"; #through; case "ko"; #through; case "th"; #through; case "vi"; return .Other;
		case "ru"; #through; case "uk"; #through; case "hr"; return .One_Few_Many;
		case "pl"; return .Polish;
		case "cs"; return .Czech;
		case "lt"; return .Lithuanian;
		case "ro"; return .Romanian;
	}
	return .One_Other;
}

plural_index :: (n: s64) -> int {
	n = abs(n);
	m10, m100 := n % 10, n % 100;
	teen := m100 >= 12 && m100 <= 14;
	if i18n.rule == {
		case .Zero_One_Other; return ifx n <= 1 then 0 else 1;
		case .Other; return 0;
		case .One_Few_Many; return ifx m10 == 1 && m100 != 11 then 0 else ifx m10 >= 2 && m10 <= 4 && !teen then 1 else 2;
		case .Polish; return ifx n == 1 then 0 else ifx m10 >= 2 && m10 <= 4 && !teen then 1 else 2;
		case .Czech; return ifx n == 1 then 0 else ifx n >= 2 && n <= 4 then 1 else 2;
		case .Lithuanian; return ifx m100 >= 11 && m100 <= 19 then 2 else ifx m10 == 1 then 0 else ifx m10 >= 2 then 1 else 2;
		case .Romanian; return ifx n == 1 then 0 else ifx n == 0 || (m100 >= 2 && m100 <= 19) then 1 else 2;
	}
	return ifx n == 1 then 0 else 1;
}

plural_form :: (forms: string, n: s64) -> string { return list_item(forms, plural_index(n)); }

// The i-th of "a|b|c" (the last when there are fewer).
list_item :: (list: string, i: int) -> string {
	s := list;
	for 1..i {
		bar := find_index_from_left(s, #char "|");
		if bar < 0 break;
		advance(*s, bar + 1);
	}
	bar := find_index_from_left(s, #char "|");
	return ifx bar >= 0 then slice(s, 0, bar) else s;
}

// A key or translation as lang files write it: \n, \t and \\ escaped.
escape_key :: (s: string) -> string {
	if !contains(s, "\\") && !contains(s, "\n") && !contains(s, "\t") return s;
	return replace(replace(replace(s, "\\", "\\\\",, temp), "\n", "\\n",, temp), "\t", "\\t",, temp);
}

unescape :: (s: string) -> string {
	if !contains(s, "\\") return copy_string(s);
	sb: String_Builder;
	i := 0;
	while i < s.count {
		c := s[i];
		if c == #char "\\" && i + 1 < s.count {
			i += 1;
			c = s[i];
			if c == #char "n" c = #char "\n"; else if c == #char "t" c = #char "\t";
		}
		append(*sb, c);
		i += 1;
	}
	return builder_to_string(*sb);
}

// Binary search over KEYS (sorted by bytes); also run at compile time by L.
key_index :: (s: string) -> int {
	lo, hi := 0, KEYS.count - 1;
	while lo <= hi {
		mid := (lo + hi) / 2;
		c := byte_compare(KEYS[mid], s);
		if c == 0 return mid;
		if c < 0 lo = mid + 1; else hi = mid - 1;
	}
	return -1;
}

byte_compare :: (a: string, b: string) -> int {
	for 0..min(a.count, b.count) - 1 if a[it] != b[it] return cast(int) a[it] - cast(int) b[it];
	return a.count - b.count;
}

Lang_File :: struct { code: string; text: string; }

KEYS :: #run,host -> []string {
	#import "Basic"; #import "File"; #import "String";
	text := read_entire_file(tprint("%lang/keys.txt", #filepath));
	out: [..]string;
	for split(text, "\n") if it array_add(*out, unescape_key(it));
	return out;
};

LANG_FILES :: #run,host -> []Lang_File {
	#import "Basic"; #import "File"; #import "File_Utilities"; #import "String";
	out: [..]Lang_File;
	for file_list(tprint("%lang", #filepath)) {
		name := path_filename(it);
		if !ends_with(name, ".txt") || name == "keys.txt" continue;
		array_add(*out, .{copy_string(slice(name, 0, name.count - 4)), read_entire_file(it)});
	}
	return out;
};

// keys.txt's escapes, at compile time.
unescape_key :: (s: string) -> string {
	if !contains(s, "\\") return copy_string(s);
	return unescape(s);
}
