#+build darwin
package platform

import NS "core:sys/darwin/Foundation"
import "core:strings"

// system_dark_mode: true when the OS appearance is dark (NSApp.effectiveAppearance,
// which follows System Settings > Appearance, including "Auto"). ok is false headless.
system_dark_mode :: proc() -> (dark: bool, ok: bool) {
	if is_headless() do return false, false
	app := msg(Id, cls("NSApplication"), "sharedApplication")
	if app == nil do return false, false
	ap := msg(Id, app, "effectiveAppearance")
	if ap == nil do return false, false
	name := odin_str(msg(Id, ap, "name"), context.temp_allocator)
	return strings.contains(name, "Dark"), true
}

// system_a11y: the display accommodations Chromium's media queries read on macOS
// (NSWorkspace): Reduce motion -> prefers-reduced-motion, Increase contrast ->
// prefers-contrast: more, Invert colors -> inverted-colors. macOS has no forced colors.
system_a11y :: proc() -> (a: System_A11y) {
	if is_headless() do return
	ws := msg(Id, cls("NSWorkspace"), "sharedWorkspace")
	if ws == nil do return
	a.reduce_motion = bool(msg(NS.BOOL, ws, "accessibilityDisplayShouldReduceMotion"))
	a.contrast_more = bool(msg(NS.BOOL, ws, "accessibilityDisplayShouldIncreaseContrast"))
	a.invert_colors = bool(msg(NS.BOOL, ws, "accessibilityDisplayShouldInvertColors"))
	return
}
