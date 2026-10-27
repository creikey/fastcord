// attach_main_page attaches (flattened) to the Discord app page and returns its session id.
attach_main_page :: (c: *cdp.Client) -> string, bool {
	session: string;
	ok: bool;
	targets, __e1 := cdp.call_value(c, "Target.getTargets"); if failed(__e1) return session, __e1;
	infos, _ := cdp.get(targets, "targetInfos");
	list := ifx infos.kind == .List then infos.list else .[];
	for t: list {
		if cdp.str(t, "type") != "page" { continue; }
		url := cdp.str(t, "url");
		if !strings.has_prefix(url, "https://discord.com/") && !strings.has_prefix(url, "https://canary.discord.com/") { continue; }
		if strings.contains(url, "/overlay") || strings.contains(url, "popout") { continue; }
		r, __e2 := cdp.call_value(c, "Target.attachToTarget", fmt.tprintf("{{\"targetId\":%s,\"flatten\":true}}", cdp.quote(cdp.str(t, "targetId")))); if failed(__e2) return session, __e2;
		return clone(cdp.str(r, "sessionId")), true;
	}
	return "", false;
}

// evaluate runs a JS expression in the page and returns the JSON of its value.
evaluate :: (c: *cdp.Client, session: string, expr: string, quiet := false) -> etf.Value, bool {
	result: etf.Value;
	ok: bool;
	params := fmt.tprintf("{{\"expression\":%s,\"returnByValue\":true,\"awaitPromise\":true}}", cdp.quote(expr));
	r, __e3 := cdp.call_value(c, "Runtime.evaluate", params, session); if failed(__e3) return result, __e3;
	{ _, has := cdp.get(r, "exceptionDetails");
	if has {
		if !quiet { fmt.eprintln("js exception:", cdp.str(r, "exceptionDetails", "exception", "description")); }
		return .{}, false;
	} }
	v, _ := cdp.get(r, "result", "value");
	return v, true;
}

