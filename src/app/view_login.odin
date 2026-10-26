package app

import "core:os"
import "core:strings"
import dc "fc:discord"
import "fc:platform"
import "fc:ui"

// Shown instead of the client when there is no token (or Discord rejected it):
// a short intro that explains where the token comes from and saves it.
login_view :: proc() {
	bg := ui.box("login", {.Draw_Background, .Scroll_Y, .Clip})
	bg.semantic_size = {.X = ui.pct(1), .Y = ui.fill()}
	bg.layout_axis = .X
	bg.cross_align = .Center
	bg.style.bg = T("--background-base-lower")
	ui.signal(bg)
	if ui.parent(bg) {
		filler(.X)
		col := ui.box("col")
		col.semantic_size = {.X = ui.px(560), .Y = ui.children()}
		col.layout_axis = .Y
		if ui.parent(col) {
			spacer(.Y, 48)
			card := ui.box("card", {.Draw_Background})
			card.semantic_size = {.X = ui.pct(1), .Y = ui.children()}
			card.layout_axis = .X
			card.style.bg = T("--background-base-low")
			card.style.radius = 12
			if ui.parent(card) {
				spacer(.X, 32)
				body := ui.box("body")
				body.semantic_size = {.X = ui.fill(), .Y = ui.children()}
				body.layout_axis = .Y
				if ui.parent(body) do login_card_body()
				spacer(.X, 32)
			}
			spacer(.Y, 48)
		}
		filler(.X)
	}
}

@(private = "file")
para :: proc(id, text: string, font: Font_Id, size, line_h: f32, color: ui.Color) -> ^ui.Box {
	b := ui.box(id, {.Draw_Text, .Wrap_Text})
	b.text = text
	b.semantic_size = {.X = ui.pct(1), .Y = ui.text_size()}
	b.style.font = F(font)
	b.style.font_size = size
	b.style.line_height = line_h
	b.style.text_color = color
	return b
}

@(private = "file")
step :: proc(n, text: string) {
	r := ui.box(n)
	r.semantic_size = {.X = ui.pct(1), .Y = ui.children()}
	r.layout_axis = .X
	r.cross_align = .Start
	if ui.parent(r) {
		num := ui.box(strings.concatenate({n, "##num"}, context.temp_allocator), {.Draw_Background, .Draw_Text})
		num.semantic_size = {.X = ui.px(22), .Y = ui.px(22)}
		num.style.radius = 11
		num.style.bg = T("--background-brand")
		num.style.text_color = {1, 1, 1, 1}
		num.style.text_align = .Center
		num.style.font = F(.Semibold)
		num.style.font_size = 12
		spacer(.X, 12)
		para("text", text, .Normal, 15, 22, T("--text-default"))
	}
	spacer(.Y, 10)
}

@(private = "file")
login_card_body :: proc() {
	spacer(.Y, 32)
	para("title", "Welcome to fastcord", .Bold, 28, 34, T("--text-strong"))
	spacer(.Y, 8)
	para("sub", "A small, fast Discord client. It signs in with your account's token, which you copy once from Discord in a web browser.", .Normal, 16, 22, T("--text-muted"))
	spacer(.Y, 24)

	when ODIN_OS == .Darwin {
		devtools := "Open the developer tools (Cmd+Option+I) and choose the Network tab."
	} else {
		devtools := "Open the developer tools (Ctrl+Shift+I) and choose the Network tab."
	}
	step("1", "Log in to Discord in your web browser.")
	step("2", devtools)
	step("3", "Click any channel, then pick a request whose name starts with \"messages\" or \"science\".")
	step("4", "Under Request Headers, copy the value of \"authorization\" and paste it below.")

	open := ui.box("Open discord.com##open", {.Clickable, .Draw_Text, .Hot_Animation})
	open.semantic_size = {.X = ui.text_size(0), .Y = ui.px(24)}
	open.style.font = F(.Medium)
	open.style.font_size = 14
	open.style.text_color = T("--text-link")
	open.hover_cursor = .Pointer
	if ui.signal(open).clicked do platform.open_url("https://discord.com/app")
	spacer(.Y, 16)

	submitted := false
	box := row("input", {.Draw_Background, .Draw_Border, .Clickable})
	box.semantic_size = {.X = ui.pct(1), .Y = ui.px(48)}
	box.style.bg = T("--input-background-default")
	box.style.border_color = app.ui.focus == box.key ? T("--input-border-active") : T("--input-border-default")
	box.style.border = 1
	box.style.radius = 8
	box.hover_cursor = .IBeam
	if app.ui.focus == 0 do app.ui.focus = box.key
	if ui.signal(box).pressed do app.ui.focus = box.key
	if ui.parent(box) {
		spacer(.X, 14)
		res := text_field("field", &app.view.token_input, "Paste your token", app.ui.focus == box.key, 15, 20, 14)
		submitted = res == .Submit
		spacer(.X, 14)
	}
	spacer(.Y, 12)

	token := clean_token(ui.editor_text(&app.view.token_input))
	r := row("actions")
	r.semantic_size = {.X = ui.pct(1), .Y = ui.px(40)}
	if ui.parent(r) {
		if app.login_error != "" {
			label(app.login_error, .Medium, 14, T("--text-feedback-critical"), 18)
		}
		filler(.X)
		btn := ui.box("Log in##login", {.Clickable, .Draw_Background, .Draw_Text, .Hot_Animation})
		btn.semantic_size = {.X = ui.text_size(32), .Y = ui.px(40)}
		btn.style.radius = 8
		btn.style.font = F(.Medium)
		btn.style.font_size = 15
		btn.style.text_align = .Center
		enabled := token != ""
		btn.style.bg = enabled ? T("--background-brand") : with_alpha(T("--background-brand"), 0.5)
		btn.style.bg_hot = btn.style.bg
		btn.style.text_color = enabled ? {1, 1, 1, 1} : {1, 1, 1, 0.5}
		btn.hover_cursor = enabled ? .Pointer : .Default
		if (ui.signal(btn).clicked || submitted) && enabled do login_with_token(token)
	}
	spacer(.Y, 24)

	para("warn1", "Treat the token like a password: anyone who has it controls your account. fastcord keeps it only on this computer.", .Normal, 13, 18, T("--text-muted"))
	spacer(.Y, 6)
	para("warn2", "Discord's terms don't allow third-party clients, so using one can get an account flagged.", .Normal, 13, 18, T("--text-muted"))
	spacer(.Y, 32)
}

// People paste the header with its name or quotes; keep only the token itself.
clean_token :: proc(s: string) -> string {
	t := strings.trim(s, "\"' \t\r\n")
	if strings.has_prefix(strings.to_lower(t, context.temp_allocator), "authorization:") do t = t[len("authorization:"):]
	return strings.trim(t, "\"' \t\r\n")
}

@(private = "file")
login_with_token :: proc(token: string) {
	dir := app_state_dir()
	os.make_directory_all(dir)
	path := strings.concatenate({dir, "/token"}, context.temp_allocator)
	if !dc.write_file_atomic(path, transmute([]byte)token) {
		app.login_error = "Couldn't save the token."
		return
	}
	ui.editor_set_text(&app.view.token_input, "")
	app.login_error = ""
	app.needs_login = false
	app.ui.focus = 0
	connect()
}

// Called each frame while connected: a rejected token sends the user back to the intro.
login_check_auth :: proc() {
	if app.client == nil || app.client.store.connection != .Auth_Failed do return
	dc.client_destroy(app.client)
	app.client = nil
	os.remove(strings.concatenate({app_state_dir(), "/token"}, context.temp_allocator))
	app.needs_login = true
	app.login_error = "Discord rejected that token. Copy it again."
}
