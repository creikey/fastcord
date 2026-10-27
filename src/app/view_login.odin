package app

import "core:crypto"
import "core:fmt"
import "core:os"
import "core:strings"
import dc "fc:discord"
import "fc:gfx"
import "fc:platform"
import "fc:qr"
import "fc:ui"

// The login page, like the official client's: the "Welcome back!" form (email
// or phone number + password, "Forgot your password?", Log In, "Need an
// account? Register") beside the QR code panel, the multi-factor step, and a
// small fastcord-only "Log in with a token" page. The requests and telemetry
// are the library's (src/discord/auth.odin, remote_auth.odin); this file only
// draws and forwards input. Without a client (fixtures, tests) the buttons
// count as offline network actions.

Login_Mode :: enum u8 {
	Form,
	Mfa,
	Token, // fastcord only: paste a token
}

Mfa_Slide :: enum u8 {
	Select,
	Totp,
	Sms,
	Backup_Warn,
	Backup,
	Unsupported, // passkeys / security keys only
}

Login_Notice :: enum u8 {
	None,
	Instructions_Sent,
	Login_Link,
}

Login_State :: struct {
	mode:           Login_Mode,
	login_ed:       ui.Editor,
	password_ed:    ui.Editor,
	code_ed:        ui.Editor,
	login_error:    string,
	password_error: string,
	message:        string, // red line above Log In (captcha, network, rejected token...)
	busy:           bool,
	methods:        dc.Mfa_Methods,
	slide:          Mfa_Slide,
	mfa_error:      string,
	sms_phone:      string,
	sms_sending:    bool,
	backup_t0:      f64, // the backup warning's 10 s countdown start
	mfa_busy:       bool,
	notice:         Login_Notice,
	notice_login:   string,
	fake_ra:        dc.Remote_Auth_View, // tests: login_state qr / ticket (no client)
	fake_ra_on:     bool,
	qr_for:         string,
	qr_code:        ^qr.Code,
	field_keys:     [2]ui.Key, // the email and password boxes (focus)
}

@(private = "file")
lg: Login_State

@(private = "file")
set_str :: proc(dst: ^string, v: string) {
	delete(dst^)
	dst^ = strings.clone(v)
}

// login_reset: back to an empty form (after a logout, or a login).
login_reset :: proc() {
	zero_editor(&lg.password_ed)
	ui.editor_set_text(&lg.login_ed, "")
	ui.editor_set_text(&lg.code_ed, "")
	set_str(&lg.login_error, "")
	set_str(&lg.password_error, "")
	set_str(&lg.mfa_error, "")
	lg.mode = .Form
	lg.busy = false
	lg.mfa_busy = false
	lg.notice = .None
	app.ui.focus = 0
}

// zero_editor wipes the editor's bytes before clearing it (the password).
@(private = "file")
zero_editor :: proc(ed: ^ui.Editor) {
	t := ui.editor_text(ed)
	if len(t) > 0 do crypto.zero_explicit(raw_data(t), len(t))
	ui.editor_set_text(ed, "")
}

// login_events: the library's results (frame(), after client_poll).
login_events :: proc() {
	if app.client == nil do return
	for ev in dc.auth_take_events(app.client) {
		switch ev.kind {
		case .Logged_In:
			login_save_token(ev.token)
			login_reset()
			app.login_error = ""
			app.needs_login = false
		case .Login_Failed:
			lg.busy = false
			set_str(&lg.login_error, ev.login_error)
			set_str(&lg.password_error, ev.password_error)
			if ev.captcha {
				set_str(&lg.message, "Discord asked for a captcha, which fastcord can't show. Log in with the QR code instead.")
			} else {
				set_str(&lg.message, ev.message)
			}
		case .Mfa_Required:
			lg.busy = false
			login_mfa_begin(ev.methods)
		case .Mfa_Failed:
			lg.mfa_busy = false
			msg := ev.message
			if msg == "" do msg = ev.login_error if ev.login_error != "" else ev.password_error
			set_str(&lg.mfa_error, msg)
		case .Sms_Sent:
			lg.sms_sending = false
			set_str(&lg.sms_phone, ev.phone)
			if ev.message != "" do set_str(&lg.mfa_error, ev.message)
		case .Forgot_Sent:
			lg.notice = .Login_Link if ev.one_time_login else .Instructions_Sent
			set_str(&lg.notice_login, ui.editor_text(&lg.login_ed))
		case .Forgot_Failed:
			set_str(&lg.login_error, ev.login_error)
			set_str(&lg.password_error, ev.password_error)
			set_str(&lg.message, ev.message)
		case .Logged_Out:
			login_reset()
			app.needs_login = true
		}
	}
}

@(private = "file")
login_save_token :: proc(token: string) {
	if token == "" || os.get_env("FASTCORD_TOKEN", context.temp_allocator) != "" do return
	dir := app_state_dir()
	os.make_directory_all(dir)
	dc.write_file_atomic(strings.concatenate({dir, "/token"}, context.temp_allocator), transmute([]byte)token)
}

// ---- page ----

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
		col.layout_axis = .Y
		col.semantic_size = {.X = ui.children(), .Y = ui.children()}
		if ui.parent(col) {
			// equal margins; the row (cross_align .Center) centers the column vertically
			spacer(.Y, 32)
			switch lg.mode {
			case .Form:
				login_form_box()
			case .Mfa:
				login_mfa_box()
			case .Token:
				login_token_box()
			}
			spacer(.Y, 32)
		}
		filler(.X)
	}
	login_notice_modal()
}

@(private = "file")
auth_box :: proc(id: string, w: f32) -> ^ui.Box {
	b := ui.box(id, {.Draw_Background, .Draw_Border})
	b.semantic_size = {.X = ui.px(w), .Y = ui.children()}
	b.layout_axis = .Y
	b.style.bg = T("--modal-background")
	b.style.border_color = T("--border-subtle")
	b.style.border = 1
	b.style.radius = 8
	return b
}

// Centered text, each wrapped line centered on its own (the boxes only center
// a layout as a whole). w: the width it wraps at.
@(private = "file")
centered :: proc(id, text: string, font: Font_Id, size, line_h: f32, color: ui.Color, w: f32 = 0) {
	col := ui.box(id)
	col.semantic_size = {.X = ui.pct(1), .Y = ui.children()}
	col.layout_axis = .Y
	ww := w if w > 0 else (col.parent != nil && col.parent.fixed_size.x > 0 ? col.parent.fixed_size.x : 400)
	tl := ui.layout_text(F(font), size, text, ww, line_h)
	if ui.parent(col) {
		for ln, i in tl.lines {
			b := ui.box(fmt.tprintf("l%d", i), {.Draw_Text})
			b.text = strings.trim_space(text[ln.start:ln.end])
			b.semantic_size = {.X = ui.pct(1), .Y = ui.px(line_h)}
			b.style.font = F(font)
			b.style.font_size = size
			b.style.line_height = line_h
			b.style.text_color = color
			b.style.text_align = .Center
		}
	}
}

// text button drawn as a link
@(private = "file")
link :: proc(text: string, size: f32 = 14, color: ui.Color = {}) -> bool {
	b := ui.box(text, {.Clickable, .Draw_Text, .Hot_Animation})
	b.semantic_size = {.X = ui.text_size(0), .Y = ui.px(size + 6)}
	b.style.font = F(.Medium)
	b.style.font_size = size
	b.style.text_color = color.a > 0 ? color : T("--text-link")
	b.hover_cursor = .Pointer
	return ui.signal(b).clicked
}

// label: "EMAIL OR PHONE NUMBER *", red with " - error" when the field has one.
@(private = "file")
field_label :: proc(id, text, err: string, required := true) {
	r := row(id)
	r.semantic_size = {.X = ui.pct(1), .Y = ui.px(16)}
	if ui.parent(r) {
		c := err != "" ? T("--text-feedback-critical") : T("--text-muted")
		label(text, .Bold, 12, c, 16)
		if err != "" {
			spacer(.X, 4)
			label(strings.concatenate({"- ", err}, context.temp_allocator), .Italic, 12, c, 16)
		} else if required {
			label(" *", .Bold, 12, T("--text-feedback-critical"), 16)
		}
	}
	spacer(.Y, 8)
}

// bordered input; returns the editor result. prefix: the phone number's country pill.
@(private = "file")
login_input :: proc(id: string, ed: ^ui.Editor, password, has_error: bool, autofocus := false, prefix := "", placeholder := "") -> (ui.Edit_Result, ui.Key) {
	box := row(id, {.Draw_Background, .Draw_Border, .Clickable})
	box.semantic_size = {.X = ui.pct(1), .Y = ui.px(40)}
	box.style.bg = T("--input-background-default")
	focused := app.ui.focus == box.key || autofocus && app.ui.focus == 0
	box.style.border_color = has_error ? T("--text-feedback-critical") : (focused ? T("--input-border-active") : T("--input-border-default"))
	box.style.border = 1
	box.style.radius = 8
	box.hover_cursor = .IBeam
	if autofocus && app.ui.focus == 0 do app.ui.focus = box.key
	focused = app.ui.focus == box.key
	if ui.signal(box).pressed do app.ui.focus = box.key
	res: ui.Edit_Result
	if ui.parent(box) {
		spacer(.X, 10)
		if prefix != "" {
			pill := ui.box("cc", {.Draw_Background, .Draw_Text})
			pill.text = prefix
			pill.semantic_size = {.X = ui.text_size(12), .Y = ui.px(24)}
			pill.style.bg = T("--background-mod-strong")
			pill.style.radius = 4
			pill.style.font = F(.Medium)
			pill.style.font_size = 13
			pill.style.text_align = .Center
			pill.style.text_color = T("--text-default")
			spacer(.X, 8)
		}
		if password {
			res = password_field("field", ed, placeholder, focused)
		} else {
			res = text_field("field", ed, placeholder, focused, 16, 20, 10, T("--input-placeholder-text-default"))
		}
		spacer(.X, 10)
	}
	return res, box.key
}

@(private = "file")
big_button :: proc(text: string, enabled := true, busy := false) -> bool {
	b := ui.box(text, {.Clickable, .Draw_Background, .Draw_Text, .Hot_Animation})
	b.semantic_size = {.X = ui.pct(1), .Y = ui.px(44)}
	b.style.radius = 8
	b.style.font = F(.Medium)
	b.style.font_size = 16
	b.style.text_align = .Center
	b.style.bg = T("--background-brand")
	b.style.bg_hot = with_alpha(b.style.bg, 0.85)
	b.style.text_color = {1, 1, 1, 1}
	b.hover_cursor = .Pointer
	if busy do b.text = strings.concatenate({"•••##", text}, context.temp_allocator)
	if !enabled || busy {
		b.flags += {.Disabled}
		b.style.bg = with_alpha(b.style.bg, 0.5)
		b.style.bg_hot = b.style.bg
		b.hover_cursor = .Default
	}
	return ui.signal(b).clicked && enabled && !busy
}

// ---- the form + QR code ----

@(private = "file")
login_form_box :: proc() {
	box := auth_box("authbox", 784)
	if ui.parent(box) {
		inner := inset_begin(32, 32)
		r := row("cols")
		r.semantic_size = {.X = ui.pct(1), .Y = ui.children()}
		r.cross_align = .Center
		if ui.parent(r) {
			form := ui.box("form")
			form.semantic_size = {.X = ui.fill(), .Y = ui.children()}
			form.layout_axis = .Y
			if ui.parent(form) do login_form()
			spacer(.X, 64)
			qcol := ui.box("qrcol")
			qcol.semantic_size = {.X = ui.px(240), .Y = ui.children()}
			qcol.layout_axis = .Y
			qcol.cross_align = .Center
			if ui.parent(qcol) do login_qr_panel()
		}
		inset_end(32, 32)
		_ = inner
	}
}

@(private = "file")
login_form :: proc() {
	centered("title", "Welcome back!", .Semibold, 24, 30, T("--text-strong"), 416)
	spacer(.Y, 8)
	centered("sub", "We're so excited to see you again!", .Normal, 16, 20, T("--text-muted"), 416)
	spacer(.Y, 20)

	text := ui.editor_text(&lg.login_ed)
	prefix := ""
	if dc.auth_is_phone(text) {
		cc := app.client != nil ? app.client.auth.country_code : ""
		if cc == "" do cc = "US"
		prefix = fmt.tprintf("%s %s", cc, dc.auth_dialing_code(cc))
	}
	field_label("login_label", "EMAIL OR PHONE NUMBER", lg.login_error)
	r1, k1 := login_input("email", &lg.login_ed, false, lg.login_error != "", autofocus = true, prefix = prefix)
	spacer(.Y, 20)
	field_label("password_label", "PASSWORD", lg.password_error)
	r2, k2 := login_input("password", &lg.password_ed, true, lg.password_error != "")
	lg.field_keys = {k1, k2}
	spacer(.Y, 4)
	if link("Forgot your password?") do login_forgot()
	spacer(.Y, 20)
	if lg.message != "" {
		set_para("msg", lg.message, .Normal, 14, 18, T("--text-feedback-critical"))
		spacer(.Y, 8)
	}
	if big_button("Log In##login", busy = lg.busy) || r1 == .Submit || r2 == .Submit do login_submit()
	spacer(.Y, 8)
	need := row("need")
	need.semantic_size = {.X = ui.pct(1), .Y = ui.px(20)}
	if ui.parent(need) {
		label("Need an account?", .Normal, 14, T("--text-muted"), 18)
		spacer(.X, 4)
		if link("Register") do open_url("https://discord.com/register")
	}
	spacer(.Y, 12)
	if link("Log in with a token", 12, T("--text-muted")) {
		lg.mode = .Token
		app.ui.focus = 0
	}
}

@(private = "file")
login_submit :: proc() {
	if lg.busy do return
	login := strings.trim_space(ui.editor_text(&lg.login_ed))
	set_str(&lg.message, "")
	set_str(&lg.login_error, "")
	set_str(&lg.password_error, "")
	if !net_action() do return
	pw := ui.editor_text(&lg.password_ed)
	dc.auth_login(app.client, login, transmute([]byte)pw)
	zero_editor(&lg.password_ed) // the request body holds the only copy now (zeroed when sent)
	lg.busy = true
}

@(private = "file")
login_forgot :: proc() {
	app.ui.focus = lg.field_keys[0]
	set_str(&lg.message, "")
	set_str(&lg.login_error, "")
	set_str(&lg.password_error, "")
	if !net_action() do return
	dc.auth_forgot(app.client, strings.trim_space(ui.editor_text(&lg.login_ed)))
}

// "Instructions Sent" / "Check your email for a login link"
@(private = "file")
login_notice_modal :: proc() {
	if lg.notice == .None do return
	scrim := ui.box("notice_scrim", {.Draw_Background, .Clickable, .Floating_X, .Floating_Y, .Overlay})
	scrim.semantic_size = {.X = ui.px(app.ui.window.x), .Y = ui.px(app.ui.window.y)}
	scrim.style.bg = {0, 0, 0, 0.7}
	if ui.signal(scrim).clicked do lg.notice = .None
	W :: 440
	d := ui.box("notice", {.Draw_Background, .Draw_Border, .Floating_X, .Floating_Y, .Overlay, .Clickable})
	d.semantic_size = {.X = ui.px(W), .Y = ui.children()}
	d.fixed_pos = {(app.ui.window.x - W) / 2, (app.ui.window.y - (d.rect.y1 - d.rect.y0)) / 2}
	d.style.bg = T("--modal-background")
	d.style.border_color = T("--border-subtle")
	d.style.border = 1
	d.style.radius = 12
	d.layout_axis = .Y
	ui.signal(d)
	if ui.parent(d) {
		inner := inset_begin(24, 24)
		if lg.notice == .Instructions_Sent {
			centered("t", "Instructions Sent", .Semibold, 24, 30, T("--text-strong"), 392)
			spacer(.Y, 8)
			centered("s", fmt.tprintf("We sent instructions to change your password to %s, please check both your inbox and spam folder.", lg.notice_login), .Normal, 16, 20, T("--text-muted"), 392)
		} else {
			centered("t", "Check your email for a login link", .Semibold, 24, 30, T("--text-strong"), 392)
			spacer(.Y, 8)
			centered("s", "Tap the link in your email to sign in instantly — no password needed.", .Normal, 16, 20, T("--text-muted"), 392)
		}
		spacer(.Y, 20)
		if big_button("Okay##ok") do lg.notice = .None
		inset_end(24, 24)
		_ = inner
	}
	for &e in app.ui.events {
		if !e.consumed && e.kind == .Key_Down && e.key == .Escape {
			lg.notice = .None
			e.consumed = true
		}
	}
}

// ---- QR code ----

@(private = "file")
login_ra_view :: proc() -> dc.Remote_Auth_View {
	if lg.fake_ra_on do return lg.fake_ra
	if app.client != nil do return dc.remote_auth_view(app.client)
	return {}
}

@(private = "file")
login_qr_panel :: proc() {
	v := login_ra_view()
	switch v.step {
	case .Initializing, .Pending_Remote_Init:
		qr_box(v.step == .Pending_Remote_Init ? v.fingerprint : "")
		spacer(.Y, 32)
		centered("qrt", "Log in with QR Code", .Semibold, 24, 30, T("--text-strong"), 240)
		spacer(.Y, 8)
		centered("qrs", "Scan this with the Discord mobile app to log in instantly.", .Normal, 16, 20, T("--text-muted"), 240)
	case .Pending_Ticket:
		av := ui.box("av", {.Draw_Background})
		av.semantic_size = {.X = ui.px(120), .Y = ui.px(120)}
		av.style.radius = 60
		av.style.bg = T("--background-mod-strong")
		if v.user_id != 0 {
			url := v.avatar != "" ? dc.avatar_url(v.user_id, v.avatar, 128) : dc.default_avatar_url(v.user_id, v.discriminator)
			if !app.sweep do set_remote_image(av, url)
		}
		spacer(.Y, 16)
		centered("qrt", "Check your phone!", .Semibold, 24, 30, T("--text-strong"), 240)
		spacer(.Y, 8)
		tag := v.username
		if v.discriminator != "" && v.discriminator != "0" do tag = fmt.tprintf("%s#%s", v.username, v.discriminator)
		centered("qrs", fmt.tprintf("Logging in as %s", tag), .Normal, 16, 20, T("--text-default"), 240)
		spacer(.Y, 16)
		if link("Not me, start over") {
			if lg.fake_ra_on do lg.fake_ra.step = .Initializing
			else if net_action() do dc.remote_auth_cancel(app.client)
		}
	case .Pending_Login, .Finish:
		spacer(.Y, 60)
		centered("qrs", "Logging in…", .Medium, 16, 20, T("--text-muted"), 240)
		spacer(.Y, 60)
	}
}

@(private = "file")
Qr_Draw :: struct {
	code: ^qr.Code,
}

// the white 176 px card; the code fills 160 px (whole-pixel modules, centered) with the logo on top
@(private = "file")
qr_box :: proc(fingerprint: string) {
	card := ui.box("qr", {.Draw_Background})
	card.semantic_size = {.X = ui.px(176), .Y = ui.px(176)}
	card.style.bg = {1, 1, 1, 1}
	card.style.radius = 4
	if fingerprint == "" do return // still connecting: the blank card
	if lg.qr_code == nil do lg.qr_code = new(qr.Code)
	if lg.qr_for != fingerprint {
		code, ok := qr.encode(dc.ra_qr_url(fingerprint), .M)
		if !ok do return
		lg.qr_code^ = code
		set_str(&lg.qr_for, fingerprint)
	}
	d := new(Qr_Draw, context.temp_allocator)
	d.code = lg.qr_code
	card.custom_draw = qr_draw
	card.custom_user = d
	if ui.parent(card) {
		logo := ui.box("logo", {.Draw_Background, .Floating_X, .Floating_Y})
		logo.semantic_size = {.X = ui.px(36), .Y = ui.px(36)}
		logo.fixed_pos = {70, 70}
		logo.style.bg = {1, 1, 1, 1}
		logo.style.radius = 8
		if ui.parent(logo) {
			ic := ui.box("ic", {.Floating_X, .Floating_Y})
			ic.semantic_size = {.X = ui.px(28), .Y = ui.px(28)}
			ic.fixed_pos = {4, 4}
			set_icon(ic, "clyde", T("--background-brand"))
		}
	}
}

@(private = "file")
qr_draw :: proc(b: ^ui.Box, user: rawptr) {
	d := (^Qr_Draw)(user)
	c := d.code
	if c == nil || c.size == 0 do return
	m := f32(int(160 / f32(c.size)))
	side := m * f32(c.size)
	x0 := b.rect.x0 + (b.rect.x1 - b.rect.x0 - side) / 2
	y0 := b.rect.y0 + (b.rect.y1 - b.rect.y0 - side) / 2
	black := gfx.Color{0, 0, 0, 1}
	for r in 0 ..< c.size {
		col := 0
		for col < c.size {
			if !qr.dark(c, r, col) {
				col += 1
				continue
			}
			start := col
			for col < c.size && qr.dark(c, r, col) do col += 1
			gfx.rect({x0 + f32(start) * m, y0 + f32(r) * m, x0 + f32(col) * m, y0 + f32(r + 1) * m}, black)
		}
	}
}

// ---- multi-factor step ----

@(private = "file")
login_mfa_begin :: proc(methods: dc.Mfa_Methods) {
	lg.mode = .Mfa
	lg.methods = methods
	set_str(&lg.mfa_error, "")
	set_str(&lg.sms_phone, "")
	ui.editor_set_text(&lg.code_ed, "")
	app.ui.focus = 0
	// the client opens on the first method (webauthn, totp, backup, sms); passkeys and
	// security keys need the browser's WebAuthn, so fastcord starts on the next one
	usable := methods - {.Webauthn}
	switch {
	case .Totp in usable:
		lg.slide = .Totp
	case .Backup in usable:
		login_mfa_slide(.Backup_Warn)
	case .Sms in usable:
		login_mfa_slide(.Sms)
	case:
		lg.slide = .Unsupported
	}
}

@(private = "file")
login_mfa_slide :: proc(s: Mfa_Slide) {
	lg.slide = s
	set_str(&lg.mfa_error, "")
	ui.editor_set_text(&lg.code_ed, "")
	app.ui.focus = 0
	if s == .Backup_Warn do lg.backup_t0 = app.ui.time
	if s == .Sms {
		set_str(&lg.sms_phone, "")
		lg.sms_sending = true
		if net_action() do dc.auth_mfa_sms_send(app.client)
	}
}

@(private = "file")
login_mfa_close :: proc() {
	if app.client != nil do dc.auth_login_reset(app.client)
	lg.mode = .Form
	app.ui.focus = 0
}

@(private = "file")
login_mfa_box :: proc() {
	box := auth_box("mfabox", 480)
	if ui.parent(box) {
		inner := inset_begin(24, 24)
		hdr := row("hdr")
		hdr.semantic_size = {.X = ui.pct(1), .Y = ui.children()}
		hdr.cross_align = .Start
		if ui.parent(hdr) {
			hc := ui.box("hc")
			hc.semantic_size = {.X = ui.fill(), .Y = ui.children()}
			hc.layout_axis = .Y
			if ui.parent(hc) {
				set_para("t", "Multi-Factor Authentication", .Semibold, 24, 30, T("--text-strong"))
				sub := ""
				switch lg.slide {
				case .Select:
					sub = "This extra step shows it's really you."
				case .Sms:
					sub = lg.sms_phone == "" ? "Sending..." : fmt.tprintf("We've sent a message to %s.  Please enter the code you received.", lg.sms_phone)
				case .Backup_Warn:
					sub = "Slow down! Are you sure?"
				case .Totp, .Backup, .Unsupported:
				}
				if sub != "" {
					spacer(.Y, 8)
					set_para("s", sub, .Semibold, 18, 24, T("--text-default"))
				}
			}
			x := ui.box("close", {.Clickable, .Hot_Animation})
			x.semantic_size = {.X = ui.px(24), .Y = ui.px(24)}
			x.hover_cursor = .Pointer
			set_icon(x, "x-large", T("--interactive-text-default"))
			if ui.signal(x).clicked do login_mfa_close()
		}
		spacer(.Y, 16)
		login_mfa_slide_body()
		inset_end(24, 24)
		_ = inner
	}
	for &e in app.ui.events {
		if !e.consumed && e.kind == .Key_Down && e.key == .Escape {
			login_mfa_close()
			e.consumed = true
		}
	}
}

@(private = "file")
mfa_method_name :: proc(m: dc.Mfa_Method) -> string {
	switch m {
	case .Webauthn:
		return "Use a passkey or security key"
	case .Totp:
		return "Use your authenticator app"
	case .Sms:
		return "Use a code sent to your phone"
	case .Backup:
		return "Use a backup code"
	}
	return ""
}

@(private = "file")
login_mfa_slide_body :: proc() {
	submit := false
	code := strings.trim_space(ui.editor_text(&lg.code_ed))
	need := 0
	switch lg.slide {
	case .Select:
		for m in ([]dc.Mfa_Method{.Webauthn, .Totp, .Backup, .Sms}) {
			if m not_in lg.methods do continue
			it := row(mfa_method_name(m), {.Clickable, .Draw_Background, .Hot_Animation})
			it.semantic_size = {.X = ui.pct(1), .Y = ui.px(48)}
			it.style.bg = T("--background-mod-subtle")
			it.style.bg_hot = T("--background-mod-normal")
			it.style.radius = 8
			it.hover_cursor = .Pointer
			if ui.parent(it) {
				spacer(.X, 16)
				label(mfa_method_name(m), .Semibold, 16, T("--text-strong"), 20)
				filler(.X)
				ic := ui.box("chev")
				ic.semantic_size = {.X = ui.px(20), .Y = ui.px(20)}
				set_icon(ic, "chevron-small-right", T("--interactive-text-default"))
				spacer(.X, 12)
			}
			if ui.signal(it).clicked {
				switch m {
				case .Webauthn:
					lg.slide = .Unsupported
				case .Totp:
					login_mfa_slide(.Totp)
				case .Backup:
					login_mfa_slide(.Backup_Warn)
				case .Sms:
					login_mfa_slide(.Sms)
				}
			}
			spacer(.Y, 8)
		}
		return
	case .Unsupported:
		set_para("u", "This account needs a passkey or security key, which fastcord can't use. Log in with the QR code instead.", .Normal, 16, 20, T("--text-default"))
		spacer(.Y, 20)
		if lg.methods - {.Webauthn} != {} {
			if set_button("Verify with something else##else", .Secondary) do login_mfa_slide(.Select)
			spacer(.Y, 8)
		}
		if big_button("Go back##back") do login_mfa_close()
		return
	case .Backup_Warn:
		set_para("w1", "Backup codes can only be used one time each and are for emergency access to your account!", .Normal, 16, 20, T("--text-default"))
		spacer(.Y, 8)
		left := 10 - int(app.ui.time - lg.backup_t0)
		if left > 0 {
			set_para("w2", fmt.tprintf("If you do not have access to any other methods, the button below will activate in %d seconds.", left), .Normal, 16, 20, T("--text-default"))
			request_wake(platform.time_now() + 0.25)
		} else {
			set_para("w2", "If you do not have access to any other methods, use the other button below to proceed.", .Normal, 16, 20, T("--text-default"))
		}
		spacer(.Y, 20)
		mfa_buttons(false, false)
		if big_button("I'm sure, use a backup code##sure", enabled = left <= 0) do login_mfa_slide(.Backup)
		return
	case .Totp, .Sms:
		need = 6
		field_label("cl", "Enter Discord Auth Code", lg.mfa_error, false)
		r := row("coderow")
		r.semantic_size = {.X = ui.pct(1), .Y = ui.px(40)}
		if ui.parent(r) {
			res, _ := login_input("code", &lg.code_ed, false, lg.mfa_error != "", autofocus = true, placeholder = "6-digit authentication code")
			submit = res == .Submit
			if lg.slide == .Sms {
				spacer(.X, 8)
				if set_button("Resend SMS?##resend", .Secondary, !lg.sms_sending, 40) {
					lg.sms_sending = true
					if net_action() do dc.auth_mfa_sms_send(app.client)
				}
			}
		}
	case .Backup:
		need = 8
		field_label("cl", "Enter Discord Backup Code", lg.mfa_error, false)
		res, _ := login_input("code", &lg.code_ed, false, lg.mfa_error != "", autofocus = true, placeholder = "8-digit backup code")
		submit = res == .Submit
	}
	if lg.mfa_error != "" {
		spacer(.Y, 8)
		set_para("err", lg.mfa_error, .Normal, 14, 18, T("--text-feedback-critical"))
	}
	spacer(.Y, 20)
	ok := lg.slide == .Backup ? len(code) >= need && len(code) <= 11 : len(code) == need
	if mfa_buttons(true, ok) || (submit && ok) do login_mfa_submit(code)
}

// "Verify with something else" (more than one method) and Confirm
@(private = "file")
mfa_buttons :: proc(confirm, enabled: bool) -> (confirmed: bool) {
	others := card(lg.methods - {.Webauthn}) > 1 || .Webauthn in lg.methods
	if !others && !confirm do return
	r := row("btns")
	r.semantic_size = {.X = ui.pct(1), .Y = ui.px(40)}
	if ui.parent(r) {
		if others && set_button("Verify with something else##else", .Secondary, true, 40) do login_mfa_slide(.Select)
		filler(.X)
		if confirm do confirmed = set_button("Confirm##confirm", .Primary, enabled && !lg.mfa_busy, 40)
	}
	spacer(.Y, 8)
	return
}

@(private = "file")
login_mfa_submit :: proc(code: string) {
	set_str(&lg.mfa_error, "")
	if !net_action() do return
	m: dc.Mfa_Method = .Totp
	#partial switch lg.slide {
	case .Backup:
		m = .Backup
	case .Sms:
		m = .Sms
	}
	dc.auth_mfa(app.client, m, code)
	lg.mfa_busy = true
}

// ---- token (fastcord only) ----

@(private = "file")
login_token_box :: proc() {
	box := auth_box("tokenbox", 560)
	if ui.parent(box) {
		inner := inset_begin(32, 32)
		login_card_body()
		inset_end(32, 32)
		_ = inner
	}
}

@(private = "file")
para :: proc(id, text: string, font: Font_Id, size, line_h: f32, color: ui.Color) -> ^ui.Box {
	return set_para(id, text, font, size, line_h, color)
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
	if link("← Back to login##back") {
		lg.mode = .Form
		app.ui.focus = 0
	}
	spacer(.Y, 12)
	para("title", "Log in with a token", .Bold, 24, 30, T("--text-strong"))
	spacer(.Y, 8)
	para("sub", "Copy your account's token once from Discord in a web browser.", .Normal, 16, 22, T("--text-muted"))
	spacer(.Y, 20)

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
	if ui.signal(open).clicked do open_url("https://discord.com/app")
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
		if (set_button("Log in##login", .Primary, token != "", 40) || submitted) && token != "" do login_with_token(token)
	}
	spacer(.Y, 20)

	para("warn1", "Treat the token like a password: anyone who has it controls your account. fastcord keeps it only on this computer.", .Normal, 13, 18, T("--text-muted"))
	spacer(.Y, 6)
	para("warn2", "Discord's terms don't allow third-party clients, so using one can get an account flagged.", .Normal, 13, 18, T("--text-muted"))
}

// People paste the header with its name or quotes; keep only the token itself.
clean_token :: proc(s: string) -> string {
	t := strings.trim(s, "\"' \t\r\n")
	if strings.has_prefix(strings.to_lower(t, context.temp_allocator), "authorization:") do t = t[len("authorization:"):]
	return strings.trim(t, "\"' \t\r\n")
}

// A pasted token connects like a launch with a saved token: the logged-out
// session (its QR socket) ends first.
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
	lg.mode = .Form
	if app.client != nil {
		client_release(app.client)
		app.client = nil
	}
	connect()
}

// Called each frame while connected: a rejected token (gateway close 4004)
// drops it and opens the login page on a fresh logged-out session.
login_check_auth :: proc() {
	if app.client == nil || app.client.store.connection != .Auth_Failed do return
	client_release(app.client)
	app.client = nil
	os.remove(strings.concatenate({app_state_dir(), "/token"}, context.temp_allocator))
	login_reset()
	app.needs_login = true
	set_str(&lg.message, "Discord didn't accept the saved login. Log in again.")
	connect()
}

// ---- tests (script command login_state) ----

// login_reset_for_test: a fresh login page (sweep resets).
login_reset_for_test :: proc() {
	login_reset()
	set_str(&lg.message, "")
	lg.fake_ra_on = false
	lg.fake_ra = {}
	set_str(&lg.qr_for, "")
	set_str(&lg.notice_login, "")
	ui.editor_set_text(&app.view.token_input, "")
}

// login_test_state puts the page in a state without a server: error, captcha,
// mfa, mfa_backup, mfa_select, webauthn_only, qr, ticket, token, forgot_sent.
login_test_state :: proc(state: string) -> bool {
	app.needs_login = true
	app.ui.focus = 0
	switch state {
	case "error":
		lg.mode = .Form
		set_str(&lg.login_error, "Login or password is invalid.")
		set_str(&lg.password_error, "Login or password is invalid.")
	case "captcha":
		lg.mode = .Form
		set_str(&lg.message, "Discord asked for a captcha, which fastcord can't show. Log in with the QR code instead.")
	case "mfa":
		login_mfa_begin({.Totp, .Backup})
	case "mfa_backup":
		login_mfa_begin({.Backup})
	case "mfa_select":
		login_mfa_begin({.Webauthn, .Totp, .Sms, .Backup})
		lg.slide = .Select
	case "webauthn_only":
		login_mfa_begin({.Webauthn})
	case "qr", "ticket":
		lg.mode = .Form
		lg.fake_ra_on = true
		lg.fake_ra.step = .Pending_Remote_Init if state == "qr" else .Pending_Ticket
		lg.fake_ra.fingerprint = "vMrsjaKe4q09YKG1f94GTff31h01nToRh_l70CW3rjM"
		lg.fake_ra.user_id = 1546819257420087346
		lg.fake_ra.discriminator = "0"
		lg.fake_ra.username = "dingusbattle2"
	case "token":
		lg.mode = .Token
	case "forgot_sent":
		lg.notice = .Instructions_Sent
		set_str(&lg.notice_login, "dingus@example.com")
	case:
		return false
	}
	return true
}
