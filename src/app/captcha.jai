// The captcha modal ("Wait! Are you human?") for the login page: when Discord answers a login, MFA,
// forgot-password or QR ticket request with a captcha (dc.Captcha_Required), its challenge opens in a
// small window with the system's web view (platform webview), loaded only then. The page is shown as
// https://discord.com/captcha, the official modal's origin, since the captcha's sitekey is Discord's,
// and loads the provider's widget as the client's captcha component does (rqdata through setData, the
// invisible size executing at once). The solved token goes back to the library, which sends the
// request again; closing the window cancels it.

Captcha_Outcome :: enum u8 {
	None;
	Solved; // the request goes again
	Cancelled;
	Unavailable; // no web view: captcha_unavailable_message says what to do
}

// captcha_show opens Discord's challenge (dc.Captcha_Required).
captcha_show :: (ch: dc.Captcha) {
	captcha_end();
	cap.on = true;
	cap.ch = dc.captcha_copy(ch, context.allocator);
	platform.webview_open(L("Wait! Are you human?"), captcha_page(ch), CAPTCHA_URL, 440, 640);
}

// captcha_poll (each frame while the login page shows): what became of the captcha, and the token
// (Solved) or what to install (Unavailable).
captcha_poll :: () -> Captcha_Outcome, string {
	if !cap.on return .None, "";
	for platform.webview_take() {
		if it.kind == {
		case .Closed;
			return captcha_cancel(), "";
		case .Unavailable;
			captcha_cancel();
			return .Unavailable, it.text;
		case .Message;
			found, verb, rest := split_from_left(it.text, #char " ");
			if verb == {
			case "event";
				if app.client && array_find(CAPTCHA_EVENTS, rest) dc.analytics_captcha_event(app.client, cap.ch, rest);
			case "token";
				captcha_end();
				if app.client dc.auth_captcha_answer(app.client, rest);
				return .Solved, rest;
			case "cancel";
				return captcha_cancel(), "";
			}
		}
	}
	return .None, "";
}

// captcha_unavailable_message: the login page's line when the web view can't be opened (what names
// what to install, "" when it failed otherwise).
captcha_unavailable_message :: (what: string) -> string {
	if what return tprint(L("Discord asked for a captcha, which needs %1 to show. Install it, or log in to Discord in a browser on this computer and try again, or log in with a token."), what);
	return L("Discord asked for a captcha, which fastcord couldn't show. Log in to Discord in a browser on this computer and try again, or log in with a token.");
}

// captcha_end closes the window and forgets the challenge (a login, a logout, the page leaving).
captcha_end :: () {
	if !cap.on return;
	platform.webview_close();
	dc.captcha_free(*cap.ch, context.allocator);
	cap.on = false;
}

// captcha_test (-captcha-test:<sitekey>): an invisible hCaptcha challenge for sitekey, with no client;
// prints what came of it. hCaptcha's test sitekey (10000000-ffff-ffff-ffff-000000000001) solves itself,
// which checks the web view, the page's origin and its messages end to end.
captcha_test :: (sitekey: string) -> s32 {
	captcha_show(.{service = .Hcaptcha, sitekey = sitekey, invisible = true});
	start := platform.time_now();
	while platform.time_now() - start < 60 {
		// Wayland's wait_events waits for the frame callback of a frame this loop never draws; WebKitGTK
		// runs on its own thread there, so nothing needs pumping
		#if OS == .LINUX sleep_milliseconds(50); else platform.wait_events(0.25);
		outcome, text := captcha_poll();
		if outcome == .None continue;
		print("captcha-test: % %\n", outcome, ifx outcome == .Solved then slice(text, 0, 12) else text);
		return xx ifx outcome == .Solved then 0 else 1;
	}
	print("captcha-test: timed out\n");
	captcha_end();
	return 1;
}

// captcha_page: the page for one challenge. The challenge's strings were checked to token characters
// (dc.captcha_parse), so they go into the script quoted as they are.
captcha_page :: (ch: dc.Captcha) -> string {
	return tprint(CAPTCHA_PAGE, dc.CAPTCHA_SERVICE_NAMES[ch.service], ch.sitekey, ch.rqdata, ifx ch.invisible then "true" else "false", ch.user_flow,
		L("Wait! Are you human?"), L("Please confirm you’re not a robot."), L("Couldn't load the captcha. Check your connection, then close this window and try again."));
}

#scope_file

cap: struct {
	on: bool;
	ch: dc.Captcha;
};

CAPTCHA_URL :: "https://discord.com/captcha";

// the component's captcha_event names (the "initial-load" one is dc.analytics_captcha_opened's)
CAPTCHA_EVENTS :: string.["open", "close", "verify", "error", "chal-expire", "render"];

captcha_cancel :: () -> Captcha_Outcome {
	captcha_end();
	if app.client dc.auth_captcha_cancel(app.client);
	return .Cancelled;
}

// The provider's script and its options as the client's captcha component loads them (traffic/CLIENT_RULES.md,
// "Captcha"). fcPost talks to fastcord; "event <name>" are captcha_event names, "token <key>" the solution,
// "cancel" an invisible challenge closed.
CAPTCHA_PAGE :: #string HTML
<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<style>
:root { color-scheme: light dark; }
body { margin: 0; padding: 24px 16px; font: 15px/1.4 -apple-system, "Segoe UI", system-ui, sans-serif; text-align: center; }
h1 { font-size: 22px; margin: 8px 0 6px; }
p { margin: 0 0 20px; opacity: .75; }
#c { display: inline-block; }
#e { display: none; color: #d83a42; margin-top: 16px; }
</style></head>
<body><h1>%6</h1><p>%7</p><div id="c"></div><p id="e">%8</p>
<script>
const S = {service: "%1", sitekey: "%2", rqdata: "%3", invisible: %4, flow: "%5"};
function fcPost(s) {
  try {
    if (window.chrome && window.chrome.webview) window.chrome.webview.postMessage(s);
    else window.webkit.messageHandlers.fc.postMessage(s);
  } catch (e) {}
}
function failed() { document.getElementById("e").style.display = "block"; fcPost("event error"); }
function load(src) {
  const t = document.createElement("script");
  t.src = src; t.async = true; t.onerror = failed;
  document.head.appendChild(t);
}
function solved(token) { fcPost("event verify"); fcPost("token " + token); }
if (S.service === "hcaptcha") {
  window.hcaptchaOnLoad = function () {
    let id;
    const again = function () {
      if (S.rqdata) hcaptcha.setData(id, {rqdata: S.rqdata});
      if (S.invisible) hcaptcha.execute(id);
    };
    const o = {
      "open-callback": function () { fcPost("event open"); },
      "close-callback": function () { fcPost("event close"); if (S.invisible) fcPost("cancel"); else again(); },
      "error-callback": function () { fcPost("event error"); again(); },
      "chalexpired-callback": function () { fcPost("event chal-expire"); },
      "expired-callback": function () { hcaptcha.reset(id); },
      callback: function () { solved(hcaptcha.getResponse(id)); },
      sitekey: S.sitekey
    };
    if (S.invisible) o.size = "invisible";
    id = hcaptcha.render("c", o);
    again();
  };
  load("https://js.hcaptcha.com/1/api.js?render=explicit&onload=hcaptchaOnLoad&recaptchacompat=off");
} else if (S.service === "recaptcha_enterprise") {
  load("https://www.google.com/recaptcha/enterprise.js?render=" + S.sitekey);
  const wait = setInterval(function () {
    if (!window.grecaptcha || !grecaptcha.enterprise) return;
    clearInterval(wait);
    grecaptcha.enterprise.ready(async function () {
      solved(await grecaptcha.enterprise.execute(S.sitekey, S.flow ? {action: S.flow} : undefined));
    });
  }, 100);
} else if (S.service === "turnstile") {
  window.turnstileOnLoad = function () {
    let tries = 0, id;
    id = turnstile.render("#c", {
      sitekey: S.sitekey, theme: "auto", size: "normal", retry: "never", callback: solved,
      "error-callback": function () {
        fcPost("event error");
        if (tries >= 3) return false;
        tries++;
        setTimeout(function () { turnstile.reset(id); }, 3000);
        return true;
      },
      "expired-callback": function () { fcPost("event chal-expire"); }
    });
  };
  load("https://challenges.cloudflare.com/turnstile/v0/api.js?onload=turnstileOnLoad&render=explicit");
} else {
  load("https://recaptcha.net/recaptcha/api.js?render=explicit");
  const wait = setInterval(function () {
    if (!window.grecaptcha || !grecaptcha.ready) return;
    clearInterval(wait);
    grecaptcha.ready(function () {
      grecaptcha.render("c", {sitekey: S.sitekey, callback: solved, "error-callback": function () { fcPost("event error"); }});
      fcPost("event render");
    });
  }, 500);
}
</script></body></html>
HTML
