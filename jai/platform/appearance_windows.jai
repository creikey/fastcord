// system_dark_mode: true when Windows' app mode is dark
// (HKCU\...\Themes\Personalize AppsUseLightTheme = 0). ok is false headless or when unset.
system_dark_mode :: () -> bool, bool {
	dark: bool;
	ok: bool;
	if is_headless() { return false, false; }
	v: win.DWORD;
	n := win.DWORD(size_of(v));
	st := win.RegGetValueW(win.HKEY_CURRENT_USER, win.L("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize"), win.L("AppsUseLightTheme"), win.RRF_RT_REG_DWORD, null, *v, *n);
	if st != 0 { return false, false; }
	return v == 0, true;
}

// system_a11y: what Chromium's media queries read on Windows: client-area
// animations off -> prefers-reduced-motion; High Contrast -> forced-colors
// (and prefers-contrast: more). No inverted-colors.
system_a11y :: () -> System_A11y {
	a: System_A11y;
	if is_headless() { return a; }
	anim: win.BOOL = true;
	if win.SystemParametersInfoW(win.SPI_GETCLIENTAREAANIMATION, 0, *anim, 0) { a.reduce_motion = !cast(bool)(anim); }
	hc := HIGHCONTRASTW.{cbSize = size_of(HIGHCONTRASTW)};
	if win.SystemParametersInfoW(win.SPI_GETHIGHCONTRAST, size_of(HIGHCONTRASTW), *hc, 0) && hc.dwFlags & HCF_HIGHCONTRASTON != 0 {
		a.forced_colors = true;
		a.contrast_more = true;
	}
	return a;
}
#scope_file

HCF_HIGHCONTRASTON :: 0x1;

HIGHCONTRASTW :: struct {
	cbSize: win.UINT;
	dwFlags: win.DWORD;
	lpszDefaultScheme: win.LPWSTR;
}
#scope_export

