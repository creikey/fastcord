// system_dark_mode: true when the OS appearance is dark (NSApp.effectiveAppearance,
// which follows System Settings > Appearance, including "Auto"). ok is false headless.
system_dark_mode :: () -> bool, bool {
	dark: bool;
	ok: bool;
	if is_headless() { return false, false; }
	app := msg(Id, cls("NSApplication"), "sharedApplication");
	if app == null { return false, false; }
	ap := msg(Id, app, "effectiveAppearance");
	if ap == null { return false, false; }
	name := odin_str(msg(Id, ap, "name"), temp);
	return strings.contains(name, "Dark"), true;
}

// system_a11y: the display accommodations Chromium's media queries read on macOS
// (NSWorkspace): Reduce motion -> prefers-reduced-motion, Increase contrast ->
// prefers-contrast: more, Invert colors -> inverted-colors. macOS has no forced colors.
system_a11y :: () -> System_A11y {
	a: System_A11y;
	if is_headless() { return a; }
	ws := msg(Id, cls("NSWorkspace"), "sharedWorkspace");
	if ws == null { return a; }
	a.reduce_motion = cast(bool)(msg(NS.BOOL, ws, "accessibilityDisplayShouldReduceMotion"));
	a.contrast_more = cast(bool)(msg(NS.BOOL, ws, "accessibilityDisplayShouldIncreaseContrast"));
	a.invert_colors = cast(bool)(msg(NS.BOOL, ws, "accessibilityDisplayShouldInvertColors"));
	return a;
}

