// Feedback for controls that wait on the network, and the loading / failed
// states of data that is still on its way. No control may look like it did
// nothing, and nothing still loading is shown as a made-up value.
//
// A button that makes a request:
//     b := ui.box(...);                       // the button, as before
//     if req_button(b, key) && req_begin(key) { dc.some_action(app.client, ...); req_end(); }
// req_button shows the client's pulsing ellipsis in place of the label while
// the request runs (the button is disabled), and a failure shows a toast.

Req_State :: enum u8 { None; Pending; Failed; Done; }

// Offline (fixture) runs have no network: scripts pick how requests end (`net hold|fail|ok`).
Req_Offline :: enum u8 { Hold; Fail; Ok; Captcha; }

req_offline: Req_Offline;

// The state of the last request made under key, and its HTTP status (0: network failure).
req_state :: (key: string) -> Req_State, int {
	r := req_find(key);
	if !r return .None, 0;
	return r.state, r.status;
}

// A failed request's error code, and whether Discord asked for a captcha.
req_error :: (key: string) -> code: int, captcha: bool {
	r := req_find(key);
	if !r return 0, false;
	return r.code, r.captcha;
}

// Discord asked for a captcha (hCaptcha, bound to discord.com): fastcord has no webview to show it.
CAPTCHA_TEXT :: "Discord asked for a captcha, which fastcord can't show. Try on discord.com.";

// Forget a finished request (the control shows its normal state again).
req_clear :: (key: string) {
	for reqs if it.key == key {
		free(it.key);
		array_unordered_remove_by_index(*reqs, it_index);
		return;
	}
}

// Starts tracking the request a control is about to make. True when online:
// make it now, then call req_end. Offline the request ends as req_offline says.
// inline_error: the control shows its own failure text (no toast).
req_begin :: (key: string, inline_error := false) -> bool {
	app.net_actions += 1;
	r := req_find(key);
	if !r {
		r = array_add(*reqs);
		r.key = copy_string(key);
	}
	req_seq += 1;
	r.tag = REQ_TAG | req_seq;
	r.state = .Pending;
	r.status, r.code, r.captcha = 0, 0, false;
	r.jobs = 0;
	r.frame = app.frame;
	r.inline_error = inline_error;
	if app.client == null return false;
	context.req_tag = r.tag;
	context.req_jobs = 0;
	return true;
}

req_end :: () {
	for * reqs if it.tag == context.req_tag {
		it.jobs = context.req_jobs;
		if it.jobs == 0 it.state = .Done; // nothing went out (a gateway op, or deferred): done
	}
	context.req_tag = 0;
	context.req_jobs = 0;
}

// handle_results: a tracked request's job finished.
req_result :: (r: dc.Rest_Result) -> bool {
	if !(r.tag & REQ_TAG) return false;
	for * reqs if it.tag == r.tag && it.state == .Pending {
		it.jobs -= 1;
		if !r.ok {
			it.state = .Failed;
			it.status, it.code, it.captcha = r.status, r.error_code, r.captcha;
			if !it.inline_error req_toast_show(r.status, r.captcha);
		} else if it.jobs <= 0 {
			it.state = .Done;
		}
	}
	return true;
}

// Once per frame: offline requests end as the script asked (a frame after they start).
req_frame :: () {
	if app.client != null || req_offline == .Hold return;
	for * reqs if it.state == .Pending && it.frame < app.frame {
		it.state = ifx req_offline == .Ok then .Done else .Failed;
		it.captcha = req_offline == .Captcha;
		if it.state == .Failed && !it.inline_error req_toast_show(0, it.captcha);
	}
}

// Decorates a button box for the request under key: while it runs the label is
// replaced by the pulsing ellipsis and presses are ignored. Returns clicked.
req_button :: (b: *ui.Box, key: string, dots := ui.Color.{1, 1, 1, 1}) -> bool {
	clicked := ui.signal(b).clicked;
	if req_state(key) != .Pending return clicked;
	color := dots; // a copy: the caller may pass b.style.text_color, cleared next
	b.flags |= .Disabled;
	b.style.text_color = .{};
	b.hover_cursor = .Default;
	w, h := b.rect.x1 - b.rect.x0, b.rect.y1 - b.rect.y0;
	ui.parent(b); defer ui.pop_parent();
	d := pulsing_dots(color);
	d.flags |= .Floating_X | .Floating_Y;
	d.fixed_pos = .{max(0.0, (w - DOTS_W) / 2), max(0.0, (h - 6) / 2)};
	return false;
}

// The client's PULSING_ELLIPSIS: three dots fading in turn.
DOTS_W :: 24;
pulsing_dots :: (color: ui.Color) -> *ui.Box {
	r := row("dots");
	r.semantic_size = .[ui.px(DOTS_W), ui.px(6)];
	{ ui.parent(r); defer ui.pop_parent();
		for i: 0..2 {
			phase := cast(float32) (app.ui.time * 1.4) - cast(float32) i * 0.15;
			k := 0.5 + 0.5 * abs(fract(phase) * 2 - 1);
			d := ui.box(tprint("d%", i), .Draw_Background);
			d.semantic_size = .[ui.px(6), ui.px(6)];
			d.style.radius = all4(3);
			d.style.bg = with_alpha(color, 0.3 + 0.7 * k);
			spacer(.X, 2);
		}
	}
	app.ui.animating = true;
	return r;
}

// Online and the gateway's READY hasn't arrived: lists and the own user are still coming.
store_loading :: () -> bool { return app.client != null && !app.client.store.ready; }

// Placeholder shapes where data is still loading (static, like the client's).
skel :: (id: string, w: float32, h: float32, round := false) -> *ui.Box {
	b := ui.box(id, .Draw_Background);
	b.semantic_size = .[ui.px(w), ui.px(h)];
	b.style.radius = all4(ifx round then h / 2 else min(h / 2, 8.0));
	b.style.bg = T("--background-mod-normal");
	return b;
}

// A failed request's toast, bottom center, for a few seconds.
req_toast :: () {
	if toast.text == "" return;
	if app.ui.time > toast.until {
		free(toast.text);
		toast = .{};
		return;
	}
	app.wake_at = ifx app.wake_at > 0 then min(app.wake_at, toast.until) else toast.until;
	t := ui.box("reqtoast", .Draw_Background | .Draw_Text | .Floating_X | .Floating_Y | .Overlay);
	t.semantic_size = .[ui.text_size(16), ui.px(36)];
	t.text = copy_string(toast.text,, temp); // toast_show may free it before this frame draws
	t.style.font = F(.Medium);
	t.style.font_size = 14;
	t.style.text_align = .Center;
	t.style.text_color = .{1, 1, 1, 1};
	t.style.bg = ifx toast.ok then T("--status-positive") else T("--status-danger");
	t.style.radius = all4(8);
	w := t.rect.x1 - t.rect.x0;
	t.fixed_pos = .{(app.ui.window.x - w) / 2, app.ui.window.y - 36 - 96 - (ifx undos then 48 else 0)}; // above the Undo toast
}

// A short notice in the same place: green when ok (a done action), red when not.
toast_show :: (text: string, ok: bool) {
	free(toast.text);
	toast = .{text = copy_string(text), until = app.ui.time + 5, ok = ok};
}

req_reset_for_test :: () {
	for reqs free(it.key);
	array_reset(*reqs);
	req_offline = .Hold;
	free(toast.text);
	toast = .{};
}

#scope_file

REQ_TAG :: (cast(u64) 1) << 62; // above any snowflake other tags carry

Req :: struct {
	key: string;
	tag: u64;
	jobs: int; // submitted and not yet answered
	state: Req_State;
	status: int;
	code: int;
	captcha: bool;
	frame: u64;
	inline_error: bool;
}

reqs: [..]Req;
req_seq: u64;
toast: Req_Toast;
Req_Toast :: struct { text: string; until: float64; ok: bool; }

req_find :: (key: string) -> *Req {
	for * reqs if it.key == key return it;
	return null;
}

req_toast_show :: (status: int, captcha := false) {
	toast_show(ifx captcha then CAPTCHA_TEXT else ifx status == 429 then L("You're doing that too fast. Try again in a moment.") else L("Something went wrong. Try again."), false);
}
