// The login page, like the official client's: the "Welcome back!" form (email
// or phone number + password, "Forgot your password?", Log In, "Need an
// account? Register") beside the QR code panel, the multi-factor step, and a
// small fastcord-only "Log in with a token" page. The requests and telemetry
// are the library's (src/discord/auth.odin, remote_auth.odin); this file only
// draws and forwards input. Without a client (fixtures, tests) the buttons
// count as offline network actions.

Login_Mode :: enum u8 {
	Form;
	Mfa;
	Token; // fastcord only: paste a token
}

Mfa_Slide :: enum u8 {
	Select;
	Totp;
	Sms;
	Backup_Warn;
	Backup;
	Unsupported; // passkeys / security keys only
}

Login_Notice :: enum u8 {
	None;
	Instructions_Sent;
	Login_Link;
}

Login_State :: struct {
	mode: Login_Mode;
	login_ed: ui.Editor;
	password_ed: ui.Editor;
	code_ed: ui.Editor;
	login_error: string;
	password_error: string;
	message: string; // red line above Log In (captcha, network, rejected token...)
	busy: bool;
	methods: dc.Mfa_Method;
	slide: Mfa_Slide;
	mfa_error: string;
	sms_phone: string;
	sms_sending: bool;
	backup_t0: float64; // the backup warning's 10 s countdown start
	mfa_busy: bool;
	notice: Login_Notice;
	notice_login: string;
	fake_ra: dc.Remote_Auth_View; // tests: login_state qr / ticket (no client)
	fake_ra_on: bool;
	qr_for: string;
	qr_code: *qr.Code_;
	field_keys: [2]ui.Key; // the email and password boxes (focus)
}

// login_reset: back to an empty form (after a logout, or a login).
login_reset :: () {
	zero_editor(*lg.password_ed);
	ui.editor_set_text(*lg.login_ed, "");
	ui.editor_set_text(*lg.code_ed, "");
	set_str(*lg.login_error, "");
	set_str(*lg.password_error, "");
	set_str(*lg.mfa_error, "");
	lg.mode = .Form;
	lg.busy = false;
	lg.mfa_busy = false;
	lg.notice = .None;
	app.ui.focus = 0;
}

// login_events: the library's results (frame(), after client_poll).
login_events :: () {
	if app.client == null { return; }
	for ev: dc.auth_take_events(app.client) {
		if ev.kind == {
		case .Logged_In;
			login_save_token(ev.token);
			login_reset();
			app.login_error = "";
			app.needs_login = false;
		case .Login_Failed;
			lg.busy = false;
			set_str(*lg.login_error, ev.login_error);
			set_str(*lg.password_error, ev.password_error);
			if ev.captcha {
				set_str(*lg.message, "Discord asked for a captcha, which fastcord can't show. Log in with the QR code instead.");
			} else {
				set_str(*lg.message, ev.message);
			}
		case .Mfa_Required;
			lg.busy = false;
			login_mfa_begin(ev.methods);
		case .Mfa_Failed;
			lg.mfa_busy = false;
			msg := ev.message;
			if msg == "" { msg = ifx ev.login_error != "" then ev.login_error else ev.password_error; }
			set_str(*lg.mfa_error, msg);
		case .Sms_Sent;
			lg.sms_sending = false;
			set_str(*lg.sms_phone, ev.phone);
			if ev.message != "" { set_str(*lg.mfa_error, ev.message); }
		case .Forgot_Sent;
			lg.notice = ifx ev.one_time_login then .Login_Link else .Instructions_Sent;
			set_str(*lg.notice_login, ui.editor_text(*lg.login_ed));
		case .Forgot_Failed;
			set_str(*lg.login_error, ev.login_error);
			set_str(*lg.password_error, ev.password_error);
			set_str(*lg.message, ev.message);
		case .Logged_Out;
			login_reset();
			app.needs_login = true;
		}
	}
}

// ---- page ----

login_view :: () {
	bg := ui.box("login", .Draw_Background | .Scroll_Y | .Clip);
	bg.semantic_size = .[ui.pct(1), ui.fill()];
	bg.layout_axis = .X;
	bg.cross_align = .Center;
	bg.style.bg = T("--background-base-lower");
	ui.signal(bg);
	{ ui.parent(bg); defer ui.pop_parent();
		filler(.X);
		col := ui.box("col");
		col.layout_axis = .Y;
		col.semantic_size = .[ui.children(), ui.children()];
		{ ui.parent(col); defer ui.pop_parent();
			// equal margins; the row (cross_align .Center) centers the column vertically
			spacer(.Y, 32);
			if lg.mode == {
			case .Form;
				login_form_box();
			case .Mfa;
				login_mfa_box();
			case .Token;
				login_token_box();
			}
			spacer(.Y, 32);
		}
		filler(.X);
	}
	login_notice_modal();
}
#scope_file

auth_box :: (id: string, w: float32) -> *ui.Box {
	b := ui.box(id, .Draw_Background | .Draw_Border);
	b.semantic_size = .[ui.px(w), ui.children()];
	b.layout_axis = .Y;
	b.style.bg = T("--modal-background");
	b.style.border_color = T("--border-subtle");
	b.style.border = 1;
	b.style.radius = all4(8);
	return b;
}

// Centered text, each wrapped line centered on its own (the boxes only center
// a layout as a whole). w: the width it wraps at.
centered :: (id: string, text: string, font: Font_Id, size: float32, line_h: float32, color: ui.Color, w: float32 = 0) {
	col := ui.box(id);
	col.semantic_size = .[ui.pct(1), ui.children()];
	col.layout_axis = .Y;
	ww := ifx w > 0 then w else (ifx col.parent != null && col.parent.fixed_size.x > 0 then col.parent.fixed_size.x else 400);
	tl := ui.layout_text(F(font), size, text, ww, line_h);
	{ ui.parent(col); defer ui.pop_parent();
		for ln, i: tl.lines {
			b := ui.box(tprint("l%", i), .Draw_Text);
			b.text = trim(string.{ln.end - ln.start, text.data + ln.start});
			b.semantic_size = .[ui.pct(1), ui.px(line_h)];
			b.style.font = F(font);
			b.style.font_size = size;
			b.style.line_height = line_h;
			b.style.text_color = color;
			b.style.text_align = .Center;
		}
	}
}

// text button drawn as a link
link :: (text: string, size: float32 = 14, color: ui.Color = .{}) -> bool {
	b := ui.box(text, .Clickable | .Draw_Text | .Hot_Animation);
	b.semantic_size = .[ui.text_size(0), ui.px(size + 6)];
	b.style.font = F(.Medium);
	b.style.font_size = size;
	b.style.text_color = ifx color.w > 0 then color else T("--text-link");
	b.hover_cursor = .Pointer;
	return ui.signal(b).clicked;
}

// label: "EMAIL OR PHONE NUMBER *", red with " - error" when the field has one.
field_label :: (id: string, text: string, err: string, required := true) {
	r := row(id);
	r.semantic_size = .[ui.pct(1), ui.px(16)];
	{ ui.parent(r); defer ui.pop_parent();
		c := ifx err != "" then T("--text-feedback-critical") else T("--text-muted");
		label(text, .Bold, 12, c, 16);
		if err != "" {
			spacer(.X, 4);
			label(tprint("- %", err), .Italic, 12, c, 16);
		} else if required {
			label(" *", .Bold, 12, T("--text-feedback-critical"), 16);
		}
	}
	spacer(.Y, 8);
}

// bordered input; returns the editor result. prefix: the phone number's country pill.
login_input :: (id: string, ed: *ui.Editor, password: bool, has_error: bool, autofocus := false, prefix := "", placeholder := "") -> ui.Edit_Result, ui.Key {
	box := row(id, .Draw_Background | .Draw_Border | .Clickable);
	box.semantic_size = .[ui.pct(1), ui.px(40)];
	box.style.bg = T("--input-background-default");
	focused := app.ui.focus == box.key || autofocus && app.ui.focus == 0;
	box.style.border_color = ifx has_error then T("--text-feedback-critical") else (ifx focused then T("--input-border-active") else T("--input-border-default"));
	box.style.border = 1;
	box.style.radius = all4(8);
	box.hover_cursor = .IBeam;
	if autofocus && app.ui.focus == 0 { app.ui.focus = box.key; }
	focused = app.ui.focus == box.key;
	if ui.signal(box).pressed { app.ui.focus = box.key; }
	res: ui.Edit_Result;
	{ ui.parent(box); defer ui.pop_parent();
		spacer(.X, 10);
		if prefix != "" {
			pill := ui.box("cc", .Draw_Background | .Draw_Text);
			pill.text = prefix;
			pill.semantic_size = .[ui.text_size(12), ui.px(24)];
			pill.style.bg = T("--background-mod-strong");
			pill.style.radius = all4(4);
			pill.style.font = F(.Medium);
			pill.style.font_size = 13;
			pill.style.text_align = .Center;
			pill.style.text_color = T("--text-default");
			spacer(.X, 8);
		}
		if password {
			res = password_field("field", ed, placeholder, focused);
		} else {
			res = text_field("field", ed, placeholder, focused, 16, 20, 10, T("--input-placeholder-text-default"));
		}
		spacer(.X, 10);
	}
	return res, box.key;
}

big_button :: (text: string, enabled := true, busy := false) -> bool {
	b := ui.box(text, .Clickable | .Draw_Background | .Draw_Text | .Hot_Animation);
	b.semantic_size = .[ui.pct(1), ui.px(44)];
	b.style.radius = all4(8);
	b.style.font = F(.Medium);
	b.style.font_size = 16;
	b.style.text_align = .Center;
	b.style.bg = T("--background-brand");
	b.style.bg_hot = with_alpha(b.style.bg, 0.85);
	b.style.text_color = .{1, 1, 1, 1};
	b.hover_cursor = .Pointer;
	if busy { b.text = tprint("•••##%", text); }
	if !enabled || busy {
		b.flags |= .Disabled;
		b.style.bg = with_alpha(b.style.bg, 0.5);
		b.style.bg_hot = b.style.bg;
		b.hover_cursor = .Default;
	}
	return ui.signal(b).clicked && enabled && !busy;
}

// ---- the form + QR code ----

login_form_box :: () {
	box := auth_box("authbox", 784);
	{ ui.parent(box); defer ui.pop_parent();
		inset_begin(32, 32);
		r := row("cols");
		r.semantic_size = .[ui.pct(1), ui.children()];
		r.cross_align = .Center;
		{ ui.parent(r); defer ui.pop_parent();
			form := ui.box("form");
			form.semantic_size = .[ui.fill(), ui.children()];
			form.layout_axis = .Y;
			{ ui.parent(form); defer ui.pop_parent(); login_form(); }
			spacer(.X, 64);
			qcol := ui.box("qrcol");
			qcol.semantic_size = .[ui.px(240), ui.children()];
			qcol.layout_axis = .Y;
			qcol.cross_align = .Center;
			{ ui.parent(qcol); defer ui.pop_parent(); login_qr_panel(); }
		}
		inset_end(32, 32);
	}
}

login_form :: () {
	centered("title", "Welcome back!", .Semibold, 24, 30, T("--text-strong"), 416);
	spacer(.Y, 8);
	centered("sub", "We're so excited to see you again!", .Normal, 16, 20, T("--text-muted"), 416);
	spacer(.Y, 20);

	text := ui.editor_text(*lg.login_ed);
	prefix := "";
	if dc.auth_is_phone(text) {
		cc := ifx app.client != null then app.client.auth.country_code else "";
		if cc == "" { cc = "US"; }
		prefix = tprint("% %", cc, dc.auth_dialing_code(cc));
	}
	field_label("login_label", "EMAIL OR PHONE NUMBER", lg.login_error);
	r1, k1 := login_input("email", *lg.login_ed, false, lg.login_error != "", autofocus = true, prefix = prefix);
	spacer(.Y, 20);
	field_label("password_label", "PASSWORD", lg.password_error);
	r2, k2 := login_input("password", *lg.password_ed, true, lg.password_error != "");
	lg.field_keys = .[k1, k2];
	spacer(.Y, 4);
	if link("Forgot your password?") { login_forgot(); }
	spacer(.Y, 20);
	if lg.message != "" {
		set_para("msg", lg.message, .Normal, 14, 18, T("--text-feedback-critical"));
		spacer(.Y, 8);
	}
	if big_button("Log In##login", busy = lg.busy) || r1 == .Submit || r2 == .Submit { login_submit(); }
	spacer(.Y, 8);
	need := row("need");
	need.semantic_size = .[ui.pct(1), ui.px(20)];
	{ ui.parent(need); defer ui.pop_parent();
		label("Need an account?", .Normal, 14, T("--text-muted"), 18);
		spacer(.X, 4);
		if link("Register") { open_url("https://discord.com/register"); }
	}
	spacer(.Y, 12);
	if link("Log in with a token", 12, T("--text-muted")) {
		lg.mode = .Token;
		app.ui.focus = 0;
	}
}

login_submit :: () {
	if lg.busy { return; }
	login := trim(ui.editor_text(*lg.login_ed));
	set_str(*lg.message, "");
	set_str(*lg.login_error, "");
	set_str(*lg.password_error, "");
	if !net_action() { return; }
	pw := ui.editor_text(*lg.password_ed);
	dc.auth_login(app.client, login, cast([]u8) pw);
	zero_editor(*lg.password_ed); // the request body holds the only copy now (zeroed when sent)
	lg.busy = true;
}

login_forgot :: () {
	app.ui.focus = lg.field_keys[0];
	set_str(*lg.message, "");
	set_str(*lg.login_error, "");
	set_str(*lg.password_error, "");
	if !net_action() { return; }
	dc.auth_forgot(app.client, trim(ui.editor_text(*lg.login_ed)));
}

// "Instructions Sent" / "Check your email for a login link"
login_notice_modal :: () {
	if lg.notice == .None { return; }
	scrim := ui.box("notice_scrim", .Draw_Background | .Clickable | .Floating_X | .Floating_Y | .Overlay);
	scrim.semantic_size = .[ui.px(app.ui.window.x), ui.px(app.ui.window.y)];
	scrim.style.bg = .{0, 0, 0, 0.7};
	if ui.signal(scrim).clicked { lg.notice = .None; }
	W :: 440;
	d := ui.box("notice", .Draw_Background | .Draw_Border | .Floating_X | .Floating_Y | .Overlay | .Clickable);
	d.semantic_size = .[ui.px(W), ui.children()];
	d.fixed_pos = .{(app.ui.window.x - W) / 2, (app.ui.window.y - (d.rect.y1 - d.rect.y0)) / 2};
	d.style.bg = T("--modal-background");
	d.style.border_color = T("--border-subtle");
	d.style.border = 1;
	d.style.radius = all4(12);
	d.layout_axis = .Y;
	ui.signal(d);
	{ ui.parent(d); defer ui.pop_parent();
		inset_begin(24, 24);
		if lg.notice == .Instructions_Sent {
			centered("t", "Instructions Sent", .Semibold, 24, 30, T("--text-strong"), 392);
			spacer(.Y, 8);
			centered("s", tprint("We sent instructions to change your password to %, please check both your inbox and spam folder.", lg.notice_login), .Normal, 16, 20, T("--text-muted"), 392);
		} else {
			centered("t", "Check your email for a login link", .Semibold, 24, 30, T("--text-strong"), 392);
			spacer(.Y, 8);
			centered("s", "Tap the link in your email to sign in instantly — no password needed.", .Normal, 16, 20, T("--text-muted"), 392);
		}
		spacer(.Y, 20);
		if big_button("Okay##ok") { lg.notice = .None; }
		inset_end(24, 24);
	}
	for * e: app.ui.events {
		if !e.consumed && e.kind == .Key_Down && e.key == .Escape {
			lg.notice = .None;
			e.consumed = true;
		}
	}
}

// ---- QR code ----

login_ra_view :: () -> dc.Remote_Auth_View {
	if lg.fake_ra_on { return lg.fake_ra; }
	if app.client != null { return dc.remote_auth_view(app.client); }
	return .{};
}

login_qr_panel :: () {
	v := login_ra_view();
	if v.step == {
	case .Initializing; #through; case .Pending_Remote_Init;
		qr_box(ifx v.step == .Pending_Remote_Init then v.fingerprint else "");
		spacer(.Y, 32);
		centered("qrt", "Log in with QR Code", .Semibold, 24, 30, T("--text-strong"), 240);
		spacer(.Y, 8);
		centered("qrs", "Scan this with the Discord mobile app to log in instantly.", .Normal, 16, 20, T("--text-muted"), 240);
	case .Pending_Ticket;
		av := ui.box("av", .Draw_Background);
		av.semantic_size = .[ui.px(120), ui.px(120)];
		av.style.radius = all4(60);
		av.style.bg = T("--background-mod-strong");
		if v.user_id != 0 {
			url := ifx v.avatar != "" then dc.avatar_url(v.user_id, v.avatar, 128) else dc.default_avatar_url(v.user_id, v.discriminator);
			if !app.sweep { set_remote_image(av, url); }
		}
		spacer(.Y, 16);
		centered("qrt", "Check your phone!", .Semibold, 24, 30, T("--text-strong"), 240);
		spacer(.Y, 8);
		tag := v.username;
		if v.discriminator != "" && v.discriminator != "0" { tag = tprint("%#%", v.username, v.discriminator); }
		centered("qrs", tprint("Logging in as %", tag), .Normal, 16, 20, T("--text-default"), 240);
		spacer(.Y, 16);
		if link("Not me, start over") {
			if lg.fake_ra_on { lg.fake_ra.step = .Initializing; } else if net_action() { dc.remote_auth_cancel(app.client); }
		}
	case .Pending_Login; #through; case .Finish;
		spacer(.Y, 60);
		centered("qrs", "Logging in…", .Medium, 16, 20, T("--text-muted"), 240);
		spacer(.Y, 60);
	}
}

Qr_Draw :: struct {
	code: *qr.Code_;
}

// the white 176 px card; the code fills 160 px (whole-pixel modules, centered) with the logo on top
qr_box :: (fingerprint: string) {
	card := ui.box("qr", .Draw_Background);
	card.semantic_size = .[ui.px(176), ui.px(176)];
	card.style.bg = .{1, 1, 1, 1};
	card.style.radius = all4(4);
	if fingerprint == "" { return; } // still connecting: the blank card
	if lg.qr_code == null { lg.qr_code = New(qr.Code_); }
	if lg.qr_for != fingerprint {
		code, ok := qr.encode(dc.ra_qr_url(fingerprint), .M);
		if !ok { return; }
		lg.qr_code.* = code;
		set_str(*lg.qr_for, fingerprint);
	}
	d := New(Qr_Draw,, temp);
	d.code = lg.qr_code;
	card.custom_draw = qr_draw;
	card.custom_user = d;
	{ ui.parent(card); defer ui.pop_parent();
		logo := ui.box("logo", .Draw_Background | .Floating_X | .Floating_Y);
		logo.semantic_size = .[ui.px(36), ui.px(36)];
		logo.fixed_pos = .{70, 70};
		logo.style.bg = .{1, 1, 1, 1};
		logo.style.radius = all4(8);
		{ ui.parent(logo); defer ui.pop_parent();
			ic := ui.box("ic", .Floating_X | .Floating_Y);
			ic.semantic_size = .[ui.px(28), ui.px(28)];
			ic.fixed_pos = .{4, 4};
			set_icon(ic, "clyde", T("--background-brand"));
		}
	}
}

qr_draw :: (b: *ui.Box, user: *void) {
	d := cast(*Qr_Draw)(user);
	c := d.code;
	if c == null || c.size == 0 { return; }
	m := cast(float32)(cast(int)(160 / cast(float32)(c.size)));
	side := m * cast(float32)(c.size);
	x0 := b.rect.x0 + (b.rect.x1 - b.rect.x0 - side) / 2;
	y0 := b.rect.y0 + (b.rect.y1 - b.rect.y0 - side) / 2;
	black := gfx.Color.{0, 0, 0, 1};
	for r: 0..cast(int)(c.size)-1 {
		col := 0;
		while col < c.size {
			if !qr.dark(c, r, col) {
				col += 1;
				continue;
			}
			start := col;
			while col < c.size && qr.dark(c, r, col) { col += 1; }
			gfx.rect(.{x0 + cast(float32)(start) * m, y0 + cast(float32)(r) * m, x0 + cast(float32)(col) * m, y0 + cast(float32)(r + 1) * m}, black);
		}
	}
}

// ---- multi-factor step ----

login_mfa_begin :: (methods: dc.Mfa_Method) {
	lg.mode = .Mfa;
	lg.methods = methods;
	set_str(*lg.mfa_error, "");
	set_str(*lg.sms_phone, "");
	ui.editor_set_text(*lg.code_ed, "");
	app.ui.focus = 0;
	// the client opens on the first method (webauthn, totp, backup, sms); passkeys and
	// security keys need the browser's WebAuthn, so fastcord starts on the next one
	usable := methods & ~dc.Mfa_Method.Webauthn;
	if usable & .Totp {
		lg.slide = .Totp;
	} else if usable & .Backup {
		login_mfa_slide(.Backup_Warn);
	} else if usable & .Sms {
		login_mfa_slide(.Sms);
	} else {
		lg.slide = .Unsupported;
	}
}

login_mfa_slide :: (s: Mfa_Slide) {
	lg.slide = s;
	set_str(*lg.mfa_error, "");
	ui.editor_set_text(*lg.code_ed, "");
	app.ui.focus = 0;
	if s == .Backup_Warn { lg.backup_t0 = app.ui.time; }
	if s == .Sms {
		set_str(*lg.sms_phone, "");
		lg.sms_sending = true;
		if net_action() { dc.auth_mfa_sms_send(app.client); }
	}
}

login_mfa_close :: () {
	if app.client != null { dc.auth_login_reset(app.client); }
	lg.mode = .Form;
	app.ui.focus = 0;
}

login_mfa_box :: () {
	box := auth_box("mfabox", 480);
	{ ui.parent(box); defer ui.pop_parent();
		inset_begin(24, 24);
		hdr := row("hdr");
		hdr.semantic_size = .[ui.pct(1), ui.children()];
		hdr.cross_align = .Start;
		{ ui.parent(hdr); defer ui.pop_parent();
			hc := ui.box("hc");
			hc.semantic_size = .[ui.fill(), ui.children()];
			hc.layout_axis = .Y;
			{ ui.parent(hc); defer ui.pop_parent();
				set_para("t", "Multi-Factor Authentication", .Semibold, 24, 30, T("--text-strong"));
				sub := "";
				if lg.slide == {
				case .Select;
					sub = "This extra step shows it's really you.";
				case .Sms;
					sub = ifx lg.sms_phone == "" then "Sending..." else tprint("We've sent a message to %.  Please enter the code you received.", lg.sms_phone);
				case .Backup_Warn;
					sub = "Slow down! Are you sure?";
				case .Totp; #through; case .Backup; #through; case .Unsupported;
				}
				if sub != "" {
					spacer(.Y, 8);
					set_para("s", sub, .Semibold, 18, 24, T("--text-default"));
				}
			}
			x := ui.box("close", .Clickable | .Hot_Animation);
			x.semantic_size = .[ui.px(24), ui.px(24)];
			x.hover_cursor = .Pointer;
			set_icon(x, "x-large", T("--interactive-text-default"));
			if ui.signal(x).clicked { login_mfa_close(); }
		}
		spacer(.Y, 16);
		login_mfa_slide_body();
		inset_end(24, 24);
	}
	for * e: app.ui.events {
		if !e.consumed && e.kind == .Key_Down && e.key == .Escape {
			login_mfa_close();
			e.consumed = true;
		}
	}
}

mfa_method_name :: (m: dc.Mfa_Method) -> string {
	if m == {
	case .Webauthn;
		return "Use a passkey or security key";
	case .Totp;
		return "Use your authenticator app";
	case .Sms;
		return "Use a code sent to your phone";
	case .Backup;
		return "Use a backup code";
	}
	return "";
}

login_mfa_slide_body :: () {
	submit := false;
	code := trim(ui.editor_text(*lg.code_ed));
	need := 0;
	if lg.slide == {
	case .Select;
		for m: (dc.Mfa_Method.[.Webauthn, .Totp, .Backup, .Sms]) {
			if !(lg.methods & m) { continue; }
			item := row(mfa_method_name(m), .Clickable | .Draw_Background | .Hot_Animation);
			item.semantic_size = .[ui.pct(1), ui.px(48)];
			item.style.bg = T("--background-mod-subtle");
			item.style.bg_hot = T("--background-mod-normal");
			item.style.radius = all4(8);
			item.hover_cursor = .Pointer;
			{ ui.parent(item); defer ui.pop_parent();
				spacer(.X, 16);
				label(mfa_method_name(m), .Semibold, 16, T("--text-strong"), 20);
				filler(.X);
				ic := ui.box("chev");
				ic.semantic_size = .[ui.px(20), ui.px(20)];
				set_icon(ic, "chevron-small-right", T("--interactive-text-default"));
				spacer(.X, 12);
			}
			if ui.signal(item).clicked {
				if m == {
				case .Webauthn;
					lg.slide = .Unsupported;
				case .Totp;
					login_mfa_slide(.Totp);
				case .Backup;
					login_mfa_slide(.Backup_Warn);
				case .Sms;
					login_mfa_slide(.Sms);
				}
			}
			spacer(.Y, 8);
		}
		return;
	case .Unsupported;
		set_para("u", "This account needs a passkey or security key, which fastcord can't use. Log in with the QR code instead.", .Normal, 16, 20, T("--text-default"));
		spacer(.Y, 20);
		if (lg.methods & ~dc.Mfa_Method.Webauthn) != 0 {
			if set_button("Verify with something else##else", .Secondary) { login_mfa_slide(.Select); }
			spacer(.Y, 8);
		}
		if big_button("Go back##back") { login_mfa_close(); }
		return;
	case .Backup_Warn;
		set_para("w1", "Backup codes can only be used one time each and are for emergency access to your account!", .Normal, 16, 20, T("--text-default"));
		spacer(.Y, 8);
		left := 10 - cast(int)(app.ui.time - lg.backup_t0);
		if left > 0 {
			set_para("w2", tprint("If you do not have access to any other methods, the button below will activate in % seconds.", left), .Normal, 16, 20, T("--text-default"));
			request_wake(platform.time_now() + 0.25);
		} else {
			set_para("w2", "If you do not have access to any other methods, use the other button below to proceed.", .Normal, 16, 20, T("--text-default"));
		}
		spacer(.Y, 20);
		mfa_buttons(false, false);
		if big_button("I'm sure, use a backup code##sure", enabled = left <= 0) { login_mfa_slide(.Backup); }
		return;
	case .Totp; #through; case .Sms;
		need = 6;
		field_label("cl", "Enter Discord Auth Code", lg.mfa_error, false);
		r := row("coderow");
		r.semantic_size = .[ui.pct(1), ui.px(40)];
		{ ui.parent(r); defer ui.pop_parent();
			res, _ := login_input("code", *lg.code_ed, false, lg.mfa_error != "", autofocus = true, placeholder = "6-digit authentication code");
			submit = res == .Submit;
			if lg.slide == .Sms {
				spacer(.X, 8);
				if set_button("Resend SMS?##resend", .Secondary, !lg.sms_sending, 40) {
					lg.sms_sending = true;
					if net_action() { dc.auth_mfa_sms_send(app.client); }
				}
			}
		}
	case .Backup;
		need = 8;
		field_label("cl", "Enter Discord Backup Code", lg.mfa_error, false);
		res, _ := login_input("code", *lg.code_ed, false, lg.mfa_error != "", autofocus = true, placeholder = "8-digit backup code");
		submit = res == .Submit;
	}
	if lg.mfa_error != "" {
		spacer(.Y, 8);
		set_para("err", lg.mfa_error, .Normal, 14, 18, T("--text-feedback-critical"));
	}
	spacer(.Y, 20);
	ok := ifx lg.slide == .Backup then code.count >= need && code.count <= 11 else code.count == need;
	if mfa_buttons(true, ok) || (submit && ok) { login_mfa_submit(code); }
}

// "Verify with something else" (more than one method) and Confirm
mfa_buttons :: (confirm: bool, enabled: bool) -> bool {
	confirmed: bool;
	usable := cast(u8) (lg.methods & ~dc.Mfa_Method.Webauthn);
	others := (usable & (usable - 1)) != 0 || (lg.methods & .Webauthn); // two or more usable methods, or a passkey
	if !others && !confirm { return confirmed; }
	r := row("btns");
	r.semantic_size = .[ui.pct(1), ui.px(40)];
	{ ui.parent(r); defer ui.pop_parent();
		if others && set_button("Verify with something else##else", .Secondary, true, 40) { login_mfa_slide(.Select); }
		filler(.X);
		if confirm { confirmed = set_button("Confirm##confirm", .Primary, enabled && !lg.mfa_busy, 40); }
	}
	spacer(.Y, 8);
	return confirmed;
}

login_mfa_submit :: (code: string) {
	set_str(*lg.mfa_error, "");
	if !net_action() { return; }
	m: dc.Mfa_Method = .Totp;
	if lg.slide == {
	case .Backup;
		m = .Backup;
	case .Sms;
		m = .Sms;
	}
	dc.auth_mfa(app.client, m, code);
	lg.mfa_busy = true;
}

// ---- token (fastcord only) ----

login_token_box :: () {
	box := auth_box("tokenbox", 560);
	{ ui.parent(box); defer ui.pop_parent();
		inset_begin(32, 32);
		login_card_body();
		inset_end(32, 32);
	}
}

para :: (id: string, text: string, font: Font_Id, size: float32, line_h: float32, color: ui.Color) -> *ui.Box {
	return set_para(id, text, font, size, line_h, color);
}

step :: (n: string, text: string) {
	r := ui.box(n);
	r.semantic_size = .[ui.pct(1), ui.children()];
	r.layout_axis = .X;
	r.cross_align = .Start;
	{ ui.parent(r); defer ui.pop_parent();
		num := ui.box(tprint("%##num", n), .Draw_Background | .Draw_Text);
		num.semantic_size = .[ui.px(22), ui.px(22)];
		num.style.radius = all4(11);
		num.style.bg = T("--background-brand");
		num.style.text_color = .{1, 1, 1, 1};
		num.style.text_align = .Center;
		num.style.font = F(.Semibold);
		num.style.font_size = 12;
		spacer(.X, 12);
		para("text", text, .Normal, 15, 22, T("--text-default"));
	}
	spacer(.Y, 10);
}

login_card_body :: () {
	if link("← Back to login##back") {
		lg.mode = .Form;
		app.ui.focus = 0;
	}
	spacer(.Y, 12);
	para("title", "Log in with a token", .Bold, 24, 30, T("--text-strong"));
	spacer(.Y, 8);
	para("sub", "Copy your account's token once from Discord in a web browser.", .Normal, 16, 22, T("--text-muted"));
	spacer(.Y, 20);

	#if OS == .MACOS {
		devtools := "Open the developer tools (Cmd+Option+I) and choose the Network tab.";
	} else {
		devtools := "Open the developer tools (Ctrl+Shift+I) and choose the Network tab.";
	}
	step("1", "Log in to Discord in your web browser.");
	step("2", devtools);
	step("3", "Click any channel, then pick a request whose name starts with \"messages\" or \"science\".");
	step("4", "Under Request Headers, copy the value of \"authorization\" and paste it below.");

	open := ui.box("Open discord.com##open", .Clickable | .Draw_Text | .Hot_Animation);
	open.semantic_size = .[ui.text_size(0), ui.px(24)];
	open.style.font = F(.Medium);
	open.style.font_size = 14;
	open.style.text_color = T("--text-link");
	open.hover_cursor = .Pointer;
	if ui.signal(open).clicked { open_url("https://discord.com/app"); }
	spacer(.Y, 16);

	submitted := false;
	box := row("input", .Draw_Background | .Draw_Border | .Clickable);
	box.semantic_size = .[ui.pct(1), ui.px(48)];
	box.style.bg = T("--input-background-default");
	box.style.border_color = ifx app.ui.focus == box.key then T("--input-border-active") else T("--input-border-default");
	box.style.border = 1;
	box.style.radius = all4(8);
	box.hover_cursor = .IBeam;
	if app.ui.focus == 0 { app.ui.focus = box.key; }
	if ui.signal(box).pressed { app.ui.focus = box.key; }
	{ ui.parent(box); defer ui.pop_parent();
		spacer(.X, 14);
		res := text_field("field", *app.view.token_input, "Paste your token", app.ui.focus == box.key, 15, 20, 14);
		submitted = res == .Submit;
		spacer(.X, 14);
	}
	spacer(.Y, 12);

	token := clean_token(ui.editor_text(*app.view.token_input));
	r := row("actions");
	r.semantic_size = .[ui.pct(1), ui.px(40)];
	{ ui.parent(r); defer ui.pop_parent();
		if app.login_error != "" {
			label(app.login_error, .Medium, 14, T("--text-feedback-critical"), 18);
		}
		filler(.X);
		if (set_button("Log in##login", .Primary, token != "", 40) || submitted) && token != "" { login_with_token(token); }
	}
	spacer(.Y, 20);

	para("warn1", "Treat the token like a password: anyone who has it controls your account. fastcord keeps it only on this computer.", .Normal, 13, 18, T("--text-muted"));
	spacer(.Y, 6);
	para("warn2", "Discord's terms don't allow third-party clients, so using one can get an account flagged.", .Normal, 13, 18, T("--text-muted"));
}
#scope_export

// People paste the header with its name or quotes; keep only the token itself.
clean_token :: (s: string) -> string {
	CUT :: "\"' \t\r\n";
	t := trim(s, CUT);
	if begins_with_nocase(t, "authorization:") { advance(*t, "authorization:".count); }
	return trim(t, CUT);
}

// Called each frame while connected: a rejected token (gateway close 4004)
// drops it and opens the login page on a fresh logged-out session.
login_check_auth :: () {
	if app.client == null || app.client.store.connection != .Auth_Failed { return; }
	client_release(app.client);
	app.client = null;
	file_delete(tprint("%/token", app_state_dir()));
	login_reset();
	app.needs_login = true;
	set_str(*lg.message, "Discord didn't accept the saved login. Log in again.");
	connect();
}

// ---- tests (script command login_state) ----

// login_reset_for_test: a fresh login page (sweep resets).
login_reset_for_test :: () {
	login_reset();
	set_str(*lg.message, "");
	lg.fake_ra_on = false;
	lg.fake_ra = .{};
	set_str(*lg.qr_for, "");
	set_str(*lg.notice_login, "");
	ui.editor_set_text(*app.view.token_input, "");
}

// login_test_state puts the page in a state without a server: error, captcha,
// mfa, mfa_backup, mfa_select, webauthn_only, qr, ticket, token, forgot_sent.
login_test_state :: (state: string) -> bool {
	app.needs_login = true;
	app.ui.focus = 0;
	if state == {
	case "error";
		lg.mode = .Form;
		set_str(*lg.login_error, "Login or password is invalid.");
		set_str(*lg.password_error, "Login or password is invalid.");
	case "captcha";
		lg.mode = .Form;
		set_str(*lg.message, "Discord asked for a captcha, which fastcord can't show. Log in with the QR code instead.");
	case "mfa";
		login_mfa_begin(.Totp | .Backup);
	case "mfa_backup";
		login_mfa_begin(.Backup);
	case "mfa_select";
		login_mfa_begin(.Webauthn | .Totp | .Sms | .Backup);
		lg.slide = .Select;
	case "webauthn_only";
		login_mfa_begin(.Webauthn);
	case "qr"; #through; case "ticket";
		lg.mode = .Form;
		lg.fake_ra_on = true;
		lg.fake_ra.step = ifx state == "qr" then .Pending_Remote_Init else .Pending_Ticket;
		lg.fake_ra.fingerprint = "vMrsjaKe4q09YKG1f94GTff31h01nToRh_l70CW3rjM";
		lg.fake_ra.user_id = 1546819257420087346;
		lg.fake_ra.discriminator = "0";
		lg.fake_ra.username = "dingusbattle2";
	case "token";
		lg.mode = .Token;
	case "forgot_sent";
		lg.notice = .Instructions_Sent;
		set_str(*lg.notice_login, "dingus@example.com");
	case;
		return false;
	}
	return true;
}

#scope_file
getenv :: (name: *u8) -> *u8 #foreign libc;

lg: Login_State;

set_str :: (dst: *string, v: string) {
	free(dst.*);
	dst.* = copy_string(v);
}

// zero_editor wipes the editor's bytes before clearing it (the password).
zero_editor :: (ed: *ui.Editor) {
	t := ui.editor_text(ed);
	if t.count > 0 { crypto.zero(cast([]u8) t); }
	ui.editor_set_text(ed, "");
}

login_save_token :: (token: string) {
	if token == "" || getenv("FASTCORD_TOKEN") { return; }
	dir := app_state_dir();
	make_directory_if_it_does_not_exist(dir, recursive = true);
	dc.write_file_atomic(tprint("%/token", dir), cast([]u8) token);
}

// A pasted token connects like a launch with a saved token: the logged-out
// session (its QR socket) ends first.
login_with_token :: (token: string) {
	dir := app_state_dir();
	make_directory_if_it_does_not_exist(dir, recursive = true);
	if !dc.write_file_atomic(tprint("%/token", dir), cast([]u8) token) {
		app.login_error = "Couldn't save the token.";
		return;
	}
	ui.editor_set_text(*app.view.token_input, "");
	app.login_error = "";
	app.needs_login = false;
	app.ui.focus = 0;
	lg.mode = .Form;
	if app.client != null {
		client_release(app.client);
		app.client = null;
	}
	connect();
}
