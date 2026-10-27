// Scenario DSL (tests/scenarios/*.scn), one command per line, `#` comments,
// ${VAR} substituted from tests/scenarios/env (KEY=VALUE lines).
//
//   use a|b                   following commands target account A (9333) or B (9334)
//   mark NAME                 step boundary (recorded for both accounts)
//   reload                    Page.reload, wait for READY and network idle
//   wait MS | pause | settle [MS]
//   wait_for SEL [MS]         until document.querySelector(SEL) exists
//   wait_gone SEL [MS]
//   wait_gw EVENT [MS]        until a gateway dispatch EVENT is received (since last action)
//   click SEL | rclick SEL | hover SEL | click_last SEL | hover_last SEL | rclick_last SEL
//   click_text SEL | TEXT     first SEL whose trimmed text, first text line or aria-label equals TEXT
//   rclick_text SEL | TEXT    same, right button (TEXT may list alternatives: A || B)
//   type TEXT                 human-paced key events
//   key NAME [ctrl|meta|shift|alt...]   Enter Escape Backspace Tab ArrowUp ArrowDown ...
//   upload SEL | PATH         DOM.setFileInputFiles on an <input type=file>
//   scroll SEL | DY           mouse wheel over SEL
//   js EXPR                   evaluate and print
//   let NAME EXPR             evaluate on the current account, store the string result as ${NAME}
//   snap NAME                 screenshot + layout dump -> .secrets/screens/<scenario>/NAME.{png,json} (also at every mark)
//   probe NAME | FILE.js      evaluate a JS file returning a string, save as NAME.json
//   optional CMD...           run CMD; failure is noted, not fatal
//   include FILE              inline another file (shared preludes, e.g. _open_test_channel.scn)
//
// SEL is a CSS selector (no spaces at top level are needed; the rest of the line is the selector).

PORT_A :: 9333;
PORT_B :: 9334;

Driver :: struct {
	accts: [2]*Recorder;
	cur: int;
	out: *Out;
	vars: Map(string, string);
	mouse: [2][2]float64;
	gw_cursor: [2]int;
	failed: bool;
	abort: bool; // watchdog tripped (atomic)
	name: string;
	done: bool; // scenario finished (atomic)
}
#scope_module

// watchdog_loop checks every recording page's JS heap while the scenario runs.
watchdog_loop :: (d: *Driver) {
	while !atomic_load(*d.done) {
		for _: 0..24 {
			if atomic_load(*d.done) { return; }
			time.sleep(200 * time.Millisecond);
		}
		for r: d.accts {
			if r != null && !heap_check(r) { atomic_store(*d.abort, true); }
		}
	}
}

human :: (lo: int, hi: int) {
	time.sleep(time.Duration(lo + rand.int_max(max(hi - lo, 1))) * time.Millisecond);
}

load_vars :: (d: *Driver, dir: string) {
	envp, _ := filepath.join(.{dir, "env"}, temp);
	data, err := os.read_entire_file(envp, context.allocator);
	if err != null { return; }
	for line: strings.split_lines(as_string(data), temp) {
		l := strings.trim_space(line);
		if len(l) == 0 || l[0] == #char "#" { continue; }
		eq := strings.index_byte(l, #char "=");
		if eq < 0 { continue; }
		at(*d.vars, strings.trim_space(sub(l, 0, eq))).* = strings.trim_space(sub_from(l, eq + 1));
	}
}

subst :: (d: *Driver, s: string) -> string {
	out := strings.builder_make(temp);
	i := 0;
	while i < len(s) {
		if i + 1 < len(s) && s[i] == #char "$" && s[i + 1] == #char "{" {
			end := strings.index_byte(sub_from(s, i), #char "}");
			if end > 0 {
				name := sub(s, i + 2, i + end);
				{ v, ok := map_find(d.vars, name);
				if ok {
					strings.write_string(*out, v);
				} else {
					fmt.eprintfln("undefined variable %s", name);
				} }
				i += end + 1;
				continue;
			}
		}
		strings.write_byte(*out, s[i]);
		i += 1;
	}
	return strings.to_string(out);
}
#scope_export

run_scenario :: (path: string, out_path: string) -> bool {
	src, err := os.read_entire_file(path, context.allocator);
	if err != null {
		fmt.eprintln("cannot read", path);
		return false;
	}
	name := filepath.stem(path);
	op := ifx out_path != "" then out_path else fmt.aprintf(".secrets/raw/%s.jsonl", name);
	if !strings.contains(op, ".secrets/") {
		fmt.eprintln("raw output must go under .secrets/");
		return false;
	}
	d: Driver;
	d.vars = Map(string, string).{};
	d.name = name;
	load_vars(*d, filepath.dir(path));
	lines := expand_includes(as_string(src), filepath.dir(path));
	uses_b := false;
	for l: lines { if strings.trim_space(l) == "use b" { uses_b = true; } }

	if !check_test_instance(PORT_A) { return false; }
	if uses_b && !check_test_instance(PORT_B) { return false; }
	out, ook := out_open(op);
	if !ook { return false; }
	d.out = out;
	defer out_close(out);
	// Whatever happens below, undo everything on the instances (detach, disable domains).
	defer for r: d.accts { if r != null { recorder_stop(r); } }
	ra, aok := recorder_start("a", PORT_A, out);
	d.accts[0] = ra;
	if !aok { return false; }
	if uses_b {
		rb, bok := recorder_start("b", PORT_B, out);
		d.accts[1] = rb;
		if !bok { return false; }
	}
	wd := thread.create_and_start_with_poly_data(*d, watchdog_loop);
	defer {
		atomic_store(*d.done, true);
		thread.join(wd);
		thread.destroy(wd);
	}
	scenario_start := time.tick_now();
	// The test windows are usually behind other windows; make the page behave as focused
	// (a real user has the window focused while acting).
	for r: d.accts { if r != null { cdp.call_value(r.c, "Emulation.setFocusEmulationEnabled", "{\"enabled\":true}", r.page_session); } }
	for i: 0..1 { d.mouse[i] = .{400 + rand.float64_() * 200, 300 + rand.float64_() * 100}; }
	out_line(out, "a", fmt.tprintf("\"note\":%s", cdp.quote(fmt.tprintf("scenario %s", name))));
	time.sleep(1500 * time.Millisecond); // let attach + Network.enable settle

	for raw_line, ln: lines {
		if atomic_load(*d.abort) {
			fmt.eprintln("aborted by watchdog");
			d.failed = true;
			break;
		}
		if time.tick_since(scenario_start) > MAX_CAPTURE_SECONDS * time.Second {
			fmt.eprintln("scenario exceeded the time cap; aborting");
			d.failed = true;
			break;
		}
		line := strings.trim_space(raw_line);
		if len(line) == 0 || line[0] == #char "#" { continue; }
		line = subst(*d, line);
		optional := false;
		if strings.has_prefix(line, "optional ") {
			optional = true;
			line = strings.trim_space(sub_from(line, len("optional ")));
		}
		fmt.printfln("[%s:%d] %s", name, ln + 1, line);
		ok, msg := exec(*d, line);
		if !ok {
			note := fmt.tprintf("line %d `%s` failed: %s", ln + 1, line, msg);
			fmt.eprintln(note);
			out_line(out, d.accts[d.cur].acct, fmt.tprintf("\"note\":%s", cdp.quote(note)));
			if !optional {
				d.failed = true;
				break;
			}
		}
		free_all(temp);
	}
	if !atomic_load(*d.abort) { settle(*d, 2000, 15000); }
	for r: d.accts { if r != null { fmt.printfln("%s: peak JS heap %.0f MB", r.acct, r.heap_peak / (1 << 20)); } }
	fmt.printfln("%s -> %s (%s)", name, op, ifx d.failed then "FAILED" else "ok");
	return !d.failed;
}
#scope_module

// expand_includes inlines `include FILE` lines (path relative to the scenario dir).
expand_includes :: (src: string, dir: string, depth := 0) -> []string {
	out := make_dynamic(string, 0, 0);
	for line: strings.split_lines(src) {
		l := strings.trim_space(line);
		if strings.has_prefix(l, "include ") && depth < 8 {
			inc := strings.trim_space(sub_from(l, len("include ")));
			p := inc;
			if !strings.has_prefix(inc, "/") { p, _ = filepath.join(.{dir, inc}); }
			data, err := os.read_entire_file(p, context.allocator);
			if err != null {
				fmt.eprintln("cannot include", p);
				append(*out, "fail_include");
				continue;
			}
			append(*out, ..expand_includes(as_string(data), dir, depth + 1));
			continue;
		}
		append(*out, line);
	}
	return view(out);
}

split_cmd :: (line: string) -> string, string {
	cmd: string;
	rest: string;
	sp := strings.index_byte(line, #char " ");
	if sp < 0 { return line, ""; }
	return sub(line, 0, sp), strings.trim_space(sub_from(line, sp + 1));
}

cur :: (d: *Driver) -> *Recorder {return d.accts[d.cur];}

exec :: (d: *Driver, line: string) -> bool, string {
	cmd, rest := split_cmd(line);
	r := cur(d);
	if cmd == {
	case "use";
		idx := ifx rest == "b" then 1 else 0;
		if d.accts[idx] == null { return false, "account not recording"; }
		d.cur = idx;
		return true, "";
	case "mark";
		for acc: d.accts { if acc != null { out_line(d.out, acc.acct, fmt.tprintf("\"mark\":%s", cdp.quote(rest))); } }
		snap(d, rest);
		return true, "";
	case "snap";
		if !snap(d, rest) { return false, "snap failed"; }
		return true, "";
	case "probe";
		bar := strings.index(rest, " | ");
		if bar < 0 { return false, "syntax: probe NAME | FILE.js"; }
		pname, file := sub(rest, 0, bar), sub_from(rest, bar + 3);
		src, ferr := os.read_entire_file(file, temp);
		if ferr != null { return false, "cannot read probe"; }
		v, ok := evaluate(r.c, r.page_session, as_string(src));
		if !ok { return false, "probe failed"; }
		text, _ := v.s, v.kind == .String;
		path := screen_path(d, pname, "json");
		os.write_entire_file(path, transmute([]u8, text));
		fmt.println("  probe ->", path);
		return true, "";
	case "wait";
		ms, _ := strconv.parse_int(rest);
		start := time.tick_now();
		while time.tick_since(start) < time.Duration(ms) * time.Millisecond {
			if atomic_load(*d.abort) { return false, "aborted"; }
			time.sleep(100 * time.Millisecond);
		}
		return true, "";
	case "pause";
		human(700, 1600);
		return true, "";
	case "settle";
		ms, _ := strconv.parse_int(rest);
		settle(d, ifx ms > 0 then ms else 1500, 20000);
		return true, "";
	case "reload";
		sync.mutex_lock(*r.mu);
		start := len(r.gw_events);
		sync.mutex_unlock(*r.mu);
		{ _, ok := cdp.call_value(r.c, "Page.reload", "{\"ignoreCache\":false}", r.page_session);
		if !ok { return false, "Page.reload"; } }
		if !wait_gw_from(r, "READY", start, 45000) { return false, "no READY after reload"; }
		settle(d, 2500, 30000);
		return true, "";
	case "wait_for"; #through; case "wait_gone";
		sel, ms := split_timeout(rest, 15000);
		js := fmt.tprintf("!!document.querySelector(%s)", cdp.quote(sel));
		want := cmd == "wait_for";
		start := time.tick_now();
		while time.tick_since(start) < time.Duration(ms) * time.Millisecond {
			v, _ := evaluate(r.c, r.page_session, js, quiet = true);
			{ b, _ := v.b, v.kind == .Bool;
			if b == want { return true, ""; } }
			time.sleep(250 * time.Millisecond);
		}
		return false, "timeout";
	case "wait_gw";
		ev, ms := split_timeout(rest, 15000);
		if !wait_gw_from(r, ev, d.gw_cursor[d.cur], ms) { return false, "no gateway event"; }
		return true, "";
	case "click"; #through; case "rclick"; #through; case "hover"; #through; case "click_last"; #through; case "hover_last"; #through; case "rclick_last";
		d.gw_cursor[d.cur] = gw_len(r);
		last := strings.has_suffix(cmd, "_last");
		finder := ifx last then fmt.tprintf("(()=>{{const l=document.querySelectorAll(%s);return l[l.length-1]}})()", cdp.quote(rest)) else fmt.tprintf("document.querySelector(%s)", cdp.quote(rest));
		pt, ok := locate(r, finder);
		if !ok { return false, "element not found"; }
		move_mouse(d, pt);
		if strings.has_prefix(cmd, "hover") { return true, ""; }
		click(d, pt, ifx strings.has_prefix(cmd, "rclick") then "right" else "left");
		human(500, 1100);
		return true, "";
	case "click_text"; #through; case "rclick_text";
		d.gw_cursor[d.cur] = gw_len(r);
		bar := strings.index(rest, " | ");
		if bar < 0 { return false, "syntax: click_text SEL | TEXT"; }
		sel, text := sub(rest, 0, bar), sub_from(rest, bar + 3);
		finder := fmt.tprintf(
			"(()=>{{const ts=%s.split(' || ');return [...document.querySelectorAll(%s)].find(e=>ts.some(t=>e.textContent.trim()===t||e.getAttribute('aria-label')===t||(e.innerText||'').trim().split('\\n')[0].trim()===t))}})()",
			cdp.quote(text),
			cdp.quote(sel),
		);
		pt, ok := locate(r, finder);
		if !ok { return false, "element with text not found"; }
		move_mouse(d, pt);
		click(d, pt, ifx cmd == "rclick_text" then "right" else "left");
		human(500, 1100);
		return true, "";
	case "type";
		d.gw_cursor[d.cur] = gw_len(r);
		for ch: rest {
			s := fmt.tprintf("%c", ch);
			kd := fmt.tprintf("{{\"type\":\"keyDown\",\"text\":%s,\"unmodifiedText\":%s,\"key\":%s}}", cdp.quote(s), cdp.quote(s), cdp.quote(s));
			cdp.call(r.c, "Input.dispatchKeyEvent", kd, r.page_session);
			human(20, 50);
			cdp.call(r.c, "Input.dispatchKeyEvent", fmt.tprintf("{{\"type\":\"keyUp\",\"key\":%s}}", cdp.quote(s)), r.page_session);
			human(60, 170);
		}
		human(300, 700);
		return true, "";
	case "key";
		d.gw_cursor[d.cur] = gw_len(r);
		{ __r2, __r3 := key(d, rest); return __r2, __r3; }
	case "upload";
		bar := strings.index(rest, " | ");
		if bar < 0 { return false, "syntax: upload SEL | PATH"; }
		sel, file := sub(rest, 0, bar), sub_from(rest, bar + 3);
		abs, _ := filepath.abs(file, temp);
		doc, ok := cdp.call_value(r.c, "DOM.getDocument", "{\"depth\":0}", r.page_session);
		if !ok { return false, "DOM.getDocument"; }
		root := cast(s64)(cdp.num(doc, "root", "nodeId"));
		q, qok := cdp.call_value(r.c, "DOM.querySelector", fmt.tprintf("{{\"nodeId\":%d,\"selector\":%s}}", root, cdp.quote(sel)), r.page_session);
		node := cast(s64)(cdp.num(q, "nodeId"));
		if !qok || node == 0 { return false, "file input not found"; }
		d.gw_cursor[d.cur] = gw_len(r);
		{ _, sok := cdp.call_value(r.c, "DOM.setFileInputFiles", fmt.tprintf("{{\"files\":[%s],\"nodeId\":%d}}", cdp.quote(abs), node), r.page_session);
		if !sok {
			return false, "setFileInputFiles";
		} }
		human(800, 1500);
		return true, "";
	case "scroll";
		bar := strings.index(rest, " | ");
		if bar < 0 { return false, "syntax: scroll SEL | DY"; }
		sel, dy := sub(rest, 0, bar), sub_from(rest, bar + 3);
		pt, ok := locate(r, fmt.tprintf("document.querySelector(%s)", cdp.quote(sel)));
		if !ok { return false, "element not found"; }
		move_mouse(d, pt);
		delta, _ := strconv.parse_f64(dy);
		steps := 6;
		for _: 0..steps-1 {
			cdp.call(r.c, "Input.dispatchMouseEvent", fmt.tprintf("{{\"type\":\"mouseWheel\",\"x\":%.1f,\"y\":%.1f,\"deltaX\":0,\"deltaY\":%.1f}}", pt.x, pt.y, delta / cast(float64)(steps)), r.page_session);
			human(30, 70);
		}
		return true, "";
	case "let";
		vname, expr := split_cmd(rest);
		v, ok := evaluate(r.c, r.page_session, expr);
		sv, is_str := v.s, v.kind == .String;
		if !ok || !is_str || sv == "" { return false, "let: no string result"; }
		at(*d.vars, clone(vname)).* = clone(sv);
		fmt.println("  let", vname);
		return true, "";
	case "js";
		v, ok := evaluate(r.c, r.page_session, rest);
		fmt.println("  =>", cdp.to_json(v));
		return ok, "js failed";
	}
	return false, "unknown command";
}
#scope_export

SCREENS_DIR :: "/Users/creikey/Documents/fastcord/.secrets/screens";
#scope_module

screen_path :: (d: *Driver, name: string, ext: string) -> string {
	dir := fmt.tprintf("%s/%s", SCREENS_DIR, d.name);
	os.make_directory_all(dir);
	safe, _ := strings.replace_all(name, "/", "_", temp);
	who := ifx d.cur == 0 then "" else ".b";
	return fmt.tprintf("%s/%s%s.%s", dir, safe, who, ext);
}

// snap saves a screenshot and a layout dump of the current account's page.
// Screens show other people's content: they stay in .secrets/screens.
snap :: (d: *Driver, name: string) -> bool {
	r := cur(d);
	shot, ok := cdp.call_value(r.c, "Page.captureScreenshot", "{\"format\":\"png\"}", r.page_session, 15 * time.Second);
	if !ok { return false; }
	png, _ := base64.decode(cdp.str(shot, "data"), allocator = temp);
	os.write_entire_file(screen_path(d, name, "png"), png);
	layout, _ := evaluate(r.c, r.page_session, #run load_file("probes/layout.js", #filepath), quiet = true);
	geometry, _ := evaluate(r.c, r.page_session, #run load_file("../probes/layout_geometry.js", #filepath), quiet = true);
	ls, _ := layout.s, layout.kind == .String;
	gs, _ := geometry.s, geometry.kind == .String;
	if ls == "" { ls = "null"; }
	body := fmt.tprintf("{{\"layout\":%s,\"geometry\":%s}}", ls, cdp.quote(gs));
	os.write_entire_file(screen_path(d, name, "json"), transmute([]u8, body));
	return true;
}

split_timeout :: (rest: string, def: int) -> string, int {
	sp := strings.last_index_byte(rest, #char " ");
	if sp > 0 {
		{ n, ok := strconv.parse_int(sub_from(rest, sp + 1));
		if ok { return strings.trim_space(sub(rest, 0, sp)), n; } }
	}
	return rest, def;
}

gw_len :: (r: *Recorder) -> int {
	sync.mutex_lock(*r.mu);
	defer sync.mutex_unlock(*r.mu);
	return len(r.gw_events);
}

wait_gw_from :: (r: *Recorder, name: string, from: int, ms: int) -> bool {
	start := time.tick_now();
	while time.tick_since(start) < time.Duration(ms) * time.Millisecond {
		if atomic_load(*r.aborted) { return false; }
		sync.mutex_lock(*r.mu);
		for i: from..len(r.gw_events)-1 {
			e := r.gw_events[i];
			if e.dir == "recv" && e.name == name {
				sync.mutex_unlock(*r.mu);
				return true;
			}
		}
		sync.mutex_unlock(*r.mu);
		time.sleep(100 * time.Millisecond);
	}
	return false;
}

// settle waits until no account had network activity for quiet_ms (cap max_ms).
settle :: (d: *Driver, quiet_ms: int, max_ms: int) {
	start := time.tick_now();
	while time.tick_since(start) < time.Duration(max_ms) * time.Millisecond {
		if atomic_load(*d.abort) { return; }
		quiet := true;
		now := rt_now(d.out);
		for r: d.accts {
			if r == null { continue; }
			sync.mutex_lock(*r.mu);
			if now - r.last_net < cast(float64)(quiet_ms) { quiet = false; }
			sync.mutex_unlock(*r.mu);
		}
		if quiet { return; }
		time.sleep(200 * time.Millisecond);
	}
}
#scope_export

Point :: [2]float64;
#scope_module

// locate scrolls the element into view if needed and returns a point inside it.
locate :: (r: *Recorder, finder: string) -> Point, bool {
	js := fmt.tprintf(
		"(()=>{{const e=%s;if(!e)return null;let b=e.getBoundingClientRect();if(b.top<0||b.bottom>innerHeight||b.left<0||b.right>innerWidth){{e.scrollIntoView({{block:'center'}});b=e.getBoundingClientRect();}}return [b.left,b.top,b.width,b.height,innerWidth,innerHeight];}})()",
		finder,
	);
	for attempt: 0..39 {
		v, ok := evaluate(r.c, r.page_session, js, quiet = attempt > 0);
		{ l, is_list := v.list, v.kind == .List;
		if ok && is_list && len(l) == 6 {
			f :: (x: etf.Value) -> float64 {
				if x.kind == {
				case .Int; n := x.i;
					return cast(float64)(n);
				case .Float; n := x.f;
					return n;
				}
				return 0;
			}
			x, y, w, h := f(l[0]), f(l[1]), f(l[2]), f(l[3]);
			if w > 0 && h > 0 {
				// a point near the centre, jittered like a person would
				px := x + w * (0.5 + (rand.float64_() - 0.5) * 0.4);
				py := y + h * (0.5 + (rand.float64_() - 0.5) * 0.4);
				return .[px, py], true;
			}
		} }
		time.sleep(250 * time.Millisecond);
	}
	return .[], false;
}

move_mouse :: (d: *Driver, to: Point) {
	r := cur(d);
	from := d.mouse[d.cur];
	dist := math.sqrt((to.x - from.x) * (to.x - from.x) + (to.y - from.y) * (to.y - from.y));
	steps := clamp(cast(int)(dist / 40), 4, 25);
	for i: 1..steps {
		t := cast(float64)(i) / cast(float64)(steps);
		e := t * t * (3 - 2 * t); // smoothstep
		x := from.x + (to.x - from.x) * e + (rand.float64_() - 0.5) * 2;
		y := from.y + (to.y - from.y) * e + (rand.float64_() - 0.5) * 2;
		if i == steps { x, y = to.x, to.y; }
		cdp.call(r.c, "Input.dispatchMouseEvent", fmt.tprintf("{{\"type\":\"mouseMoved\",\"x\":%.1f,\"y\":%.1f}}", x, y), r.page_session);
		human(8, 22);
	}
	d.mouse[d.cur] = to;
	human(80, 220);
}

click :: (d: *Driver, pt: Point, button: string) {
	r := cur(d);
	cdp.call(r.c, "Input.dispatchMouseEvent", fmt.tprintf("{{\"type\":\"mousePressed\",\"x\":%.1f,\"y\":%.1f,\"button\":\"%s\",\"clickCount\":1}}", pt.x, pt.y, button), r.page_session);
	human(60, 130);
	cdp.call(r.c, "Input.dispatchMouseEvent", fmt.tprintf("{{\"type\":\"mouseReleased\",\"x\":%.1f,\"y\":%.1f,\"button\":\"%s\",\"clickCount\":1}}", pt.x, pt.y, button), r.page_session);
}

Key_Def :: struct {
	name, code: string;
	vk: int;
	text: string;
}

KEYS := Key_Def.[
	.{"Enter", "Enter", 13, "\r"},
	.{"Escape", "Escape", 27, ""},
	.{"Backspace", "Backspace", 8, ""},
	.{"Delete", "Delete", 46, ""},
	.{"Tab", "Tab", 9, ""},
	.{"ArrowUp", "ArrowUp", 38, ""},
	.{"ArrowDown", "ArrowDown", 40, ""},
	.{"ArrowLeft", "ArrowLeft", 37, ""},
	.{"ArrowRight", "ArrowRight", 39, ""},
	.{"a", "KeyA", 65, "a"},
	.{"k", "KeyK", 75, "k"},
	.{",", "Comma", 188, ","},
	.{"[", "BracketLeft", 219, "["},
	.{"]", "BracketRight", 221, "]"},
	.{"v", "KeyV", 86, "v"}
];

key :: (d: *Driver, rest: string) -> bool, string {
	r := cur(d);
	parts := strings.fields(rest, temp);
	if len(parts) == 0 { return false, "no key"; }
	def: Key_Def;
	found := false;
	for k: KEYS { if k.name == parts[0] {def = k; found = true;} }
	if !found { return false, "unknown key"; }
	mods := 0;
	for m: sub_from(parts, 1) {
		if m == {
		case "alt";
			mods |= 1;
		case "ctrl";
			mods |= 2;
		case "meta";
			mods |= 4;
		case "shift";
			mods |= 8;
		}
	}
	text := ifx (mods & 6) == 0 then def.text else "";
	// macOS: editing shortcuts only work when the editor command is passed explicitly.
	commands := "";
	if mods == 4 {
		if def.name == {
		case "a";
			commands = ",\"commands\":[\"selectAll\"]";
		case "v";
			commands = ",\"commands\":[\"paste\"]";
		}
	}
	down := fmt.tprintf(
		"{{\"type\":\"%s\",\"key\":%s,\"code\":%s,\"windowsVirtualKeyCode\":%d,\"nativeVirtualKeyCode\":%d,\"modifiers\":%d%s%s}}",
		ifx text != "" then "keyDown" else "rawKeyDown",
		cdp.quote(def.name),
		cdp.quote(def.code),
		def.vk,
		def.vk,
		mods,
		ifx text != "" then fmt.tprintf(",\"text\":%s,\"unmodifiedText\":%s", cdp.quote(text), cdp.quote(text)) else "",
		commands,
	);
	cdp.call(r.c, "Input.dispatchKeyEvent", down, r.page_session);
	human(50, 110);
	up := fmt.tprintf("{{\"type\":\"keyUp\",\"key\":%s,\"code\":%s,\"windowsVirtualKeyCode\":%d,\"nativeVirtualKeyCode\":%d,\"modifiers\":%d}}", cdp.quote(def.name), cdp.quote(def.code), def.vk, def.vk, mods);
	cdp.call(r.c, "Input.dispatchKeyEvent", up, r.page_session);
	human(400, 900);
	return true, "";
}
#scope_export

