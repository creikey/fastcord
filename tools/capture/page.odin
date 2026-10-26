package capture

import "core:fmt"
import "core:strings"
import "cdp"
import "fc:etf"

// attach_main_page attaches (flattened) to the Discord app page and returns its session id.
attach_main_page :: proc(c: ^cdp.Client) -> (session: string, ok: bool) {
	targets := cdp.call_value(c, "Target.getTargets") or_return
	infos, _ := cdp.get(targets, "targetInfos")
	list, _ := infos.(etf.List)
	for t in list {
		if cdp.str(t, "type") != "page" do continue
		url := cdp.str(t, "url")
		if !strings.has_prefix(url, "https://discord.com/") && !strings.has_prefix(url, "https://canary.discord.com/") do continue
		if strings.contains(url, "/overlay") || strings.contains(url, "popout") do continue
		r := cdp.call_value(c, "Target.attachToTarget", fmt.tprintf(`{{"targetId":%s,"flatten":true}}`, cdp.quote(cdp.str(t, "targetId")))) or_return
		return strings.clone(cdp.str(r, "sessionId")), true
	}
	return "", false
}

// evaluate runs a JS expression in the page and returns the JSON of its value.
evaluate :: proc(c: ^cdp.Client, session, expr: string, quiet := false) -> (result: etf.Value, ok: bool) {
	params := fmt.tprintf(`{{"expression":%s,"returnByValue":true,"awaitPromise":true}}`, cdp.quote(expr))
	r := cdp.call_value(c, "Runtime.evaluate", params, session) or_return
	if _, has := cdp.get(r, "exceptionDetails"); has {
		if !quiet do fmt.eprintln("js exception:", cdp.str(r, "exceptionDetails", "exception", "description"))
		return nil, false
	}
	v, _ := cdp.get(r, "result", "value")
	return v, true
}
