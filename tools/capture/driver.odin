package capture

import "core:fmt"
import "core:math"
import "core:math/rand"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "cdp"
import "fc:etf"

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
//   rclick_text SEL | TEXT    same, right button
//   type TEXT                 human-paced key events
//   key NAME [ctrl|meta|shift|alt...]   Enter Escape Backspace Tab ArrowUp ArrowDown ...
//   upload SEL | PATH         DOM.setFileInputFiles on an <input type=file>
//   scroll SEL | DY           mouse wheel over SEL
//   js EXPR                   evaluate and print
//   optional CMD...           run CMD; failure is noted, not fatal
//   include FILE              inline another file (shared preludes, e.g. _open_test_channel.scn)
//
// SEL is a CSS selector (no spaces at top level are needed; the rest of the line is the selector).

PORT_A :: 9333
PORT_B :: 9334

Driver :: struct {
	accts:     [2]^Recorder,
	cur:       int,
	out:       ^Out,
	vars:      map[string]string,
	mouse:     [2][2]f64,
	gw_cursor: [2]int,
	failed:    bool,
	abort:     bool, // watchdog tripped (atomic)
	done:      bool, // scenario finished (atomic)
}

// watchdog_loop checks every recording page's JS heap while the scenario runs.
@(private)
watchdog_loop :: proc(d: ^Driver) {
	for !sync.atomic_load(&d.done) {
		for _ in 0 ..< 25 {
			if sync.atomic_load(&d.done) do return
			time.sleep(200 * time.Millisecond)
		}
		for r in d.accts {
			if r != nil && !heap_check(r) do sync.atomic_store(&d.abort, true)
		}
	}
}

@(private)
human :: proc(lo, hi: int) {
	time.sleep(time.Duration(lo + rand.int_max(max(hi - lo, 1))) * time.Millisecond)
}

@(private)
load_vars :: proc(d: ^Driver, dir: string) {
	envp, _ := filepath.join({dir, "env"}, context.temp_allocator)
	data, err := os.read_entire_file(envp, context.allocator)
	if err != nil do return
	for line in strings.split_lines(string(data), context.temp_allocator) {
		l := strings.trim_space(line)
		if len(l) == 0 || l[0] == '#' do continue
		eq := strings.index_byte(l, '=')
		if eq < 0 do continue
		d.vars[strings.trim_space(l[:eq])] = strings.trim_space(l[eq + 1:])
	}
}

@(private)
subst :: proc(d: ^Driver, s: string) -> string {
	out := strings.builder_make(context.temp_allocator)
	i := 0
	for i < len(s) {
		if i + 1 < len(s) && s[i] == '$' && s[i + 1] == '{' {
			end := strings.index_byte(s[i:], '}')
			if end > 0 {
				name := s[i + 2:i + end]
				if v, ok := d.vars[name]; ok {
					strings.write_string(&out, v)
				} else {
					fmt.eprintfln("undefined variable %s", name)
				}
				i += end + 1
				continue
			}
		}
		strings.write_byte(&out, s[i])
		i += 1
	}
	return strings.to_string(out)
}

run_scenario :: proc(path: string, out_path: string) -> bool {
	src, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		fmt.eprintln("cannot read", path)
		return false
	}
	name := filepath.stem(path)
	op := out_path if out_path != "" else fmt.aprintf(".secrets/raw/%s.jsonl", name)
	if !strings.contains(op, ".secrets/") {
		fmt.eprintln("raw output must go under .secrets/")
		return false
	}
	d: Driver
	d.vars = make(map[string]string)
	load_vars(&d, filepath.dir(path))
	lines := expand_includes(string(src), filepath.dir(path))
	uses_b := false
	for l in lines do if strings.trim_space(l) == "use b" do uses_b = true

	if !check_test_instance(PORT_A) do return false
	if uses_b && !check_test_instance(PORT_B) do return false
	out, ook := out_open(op)
	if !ook do return false
	d.out = out
	defer out_close(out)
	// Whatever happens below, undo everything on the instances (detach, disable domains).
	defer for r in d.accts do if r != nil do recorder_stop(r)
	ra, aok := recorder_start("a", PORT_A, out)
	d.accts[0] = ra
	if !aok do return false
	if uses_b {
		rb, bok := recorder_start("b", PORT_B, out)
		d.accts[1] = rb
		if !bok do return false
	}
	wd := thread.create_and_start_with_poly_data(&d, watchdog_loop, init_context = context)
	defer {
		sync.atomic_store(&d.done, true)
		thread.join(wd)
		thread.destroy(wd)
	}
	scenario_start := time.tick_now()
	// The test windows are usually behind other windows; make the page behave as focused
	// (a real user has the window focused while acting).
	for r in d.accts do if r != nil do cdp.call_value(r.c, "Emulation.setFocusEmulationEnabled", `{"enabled":true}`, r.page_session)
	for i in 0 ..< 2 do d.mouse[i] = {400 + rand.float64() * 200, 300 + rand.float64() * 100}
	out_line(out, "a", fmt.tprintf(`"note":%s`, cdp.quote(fmt.tprintf("scenario %s", name))))
	time.sleep(1500 * time.Millisecond) // let attach + Network.enable settle

	for raw_line, ln in lines {
		if sync.atomic_load(&d.abort) {
			fmt.eprintln("aborted by watchdog")
			d.failed = true
			break
		}
		if time.tick_since(scenario_start) > MAX_CAPTURE_SECONDS * time.Second {
			fmt.eprintln("scenario exceeded the time cap; aborting")
			d.failed = true
			break
		}
		line := strings.trim_space(raw_line)
		if len(line) == 0 || line[0] == '#' do continue
		line = subst(&d, line)
		optional := false
		if strings.has_prefix(line, "optional ") {
			optional = true
			line = strings.trim_space(line[len("optional "):])
		}
		fmt.printfln("[%s:%d] %s", name, ln + 1, line)
		ok, msg := exec(&d, line)
		if !ok {
			note := fmt.tprintf("line %d `%s` failed: %s", ln + 1, line, msg)
			fmt.eprintln(note)
			out_line(out, d.accts[d.cur].acct, fmt.tprintf(`"note":%s`, cdp.quote(note)))
			if !optional {
				d.failed = true
				break
			}
		}
		free_all(context.temp_allocator)
	}
	if !sync.atomic_load(&d.abort) do settle(&d, 2000, 15000)
	for r in d.accts do if r != nil do fmt.printfln("%s: peak JS heap %.0f MB", r.acct, r.heap_peak / (1 << 20))
	fmt.printfln("%s -> %s (%s)", name, op, "FAILED" if d.failed else "ok")
	return !d.failed
}

// expand_includes inlines `include FILE` lines (path relative to the scenario dir).
@(private)
expand_includes :: proc(src: string, dir: string, depth := 0) -> []string {
	out := make([dynamic]string)
	for line in strings.split_lines(src) {
		l := strings.trim_space(line)
		if strings.has_prefix(l, "include ") && depth < 8 {
			inc := strings.trim_space(l[len("include "):])
			p := inc
			if !strings.has_prefix(inc, "/") do p, _ = filepath.join({dir, inc})
			data, err := os.read_entire_file(p, context.allocator)
			if err != nil {
				fmt.eprintln("cannot include", p)
				append(&out, "fail_include")
				continue
			}
			append(&out, ..expand_includes(string(data), dir, depth + 1))
			continue
		}
		append(&out, line)
	}
	return out[:]
}

@(private)
split_cmd :: proc(line: string) -> (cmd, rest: string) {
	sp := strings.index_byte(line, ' ')
	if sp < 0 do return line, ""
	return line[:sp], strings.trim_space(line[sp + 1:])
}

@(private)
cur :: proc(d: ^Driver) -> ^Recorder {return d.accts[d.cur]}

@(private)
exec :: proc(d: ^Driver, line: string) -> (bool, string) {
	cmd, rest := split_cmd(line)
	r := cur(d)
	switch cmd {
	case "use":
		idx := 1 if rest == "b" else 0
		if d.accts[idx] == nil do return false, "account not recording"
		d.cur = idx
		return true, ""
	case "mark":
		for acc in d.accts do if acc != nil do out_line(d.out, acc.acct, fmt.tprintf(`"mark":%s`, cdp.quote(rest)))
		return true, ""
	case "wait":
		ms, _ := strconv.parse_int(rest)
		start := time.tick_now()
		for time.tick_since(start) < time.Duration(ms) * time.Millisecond {
			if sync.atomic_load(&d.abort) do return false, "aborted"
			time.sleep(100 * time.Millisecond)
		}
		return true, ""
	case "pause":
		human(700, 1600)
		return true, ""
	case "settle":
		ms, _ := strconv.parse_int(rest)
		settle(d, ms if ms > 0 else 1500, 20000)
		return true, ""
	case "reload":
		sync.mutex_lock(&r.mu)
		start := len(r.gw_events)
		sync.mutex_unlock(&r.mu)
		if _, ok := cdp.call_value(r.c, "Page.reload", `{"ignoreCache":false}`, r.page_session); !ok do return false, "Page.reload"
		if !wait_gw_from(r, "READY", start, 45000) do return false, "no READY after reload"
		settle(d, 2500, 30000)
		return true, ""
	case "wait_for", "wait_gone":
		sel, ms := split_timeout(rest, 15000)
		js := fmt.tprintf("!!document.querySelector(%s)", cdp.quote(sel))
		want := cmd == "wait_for"
		start := time.tick_now()
		for time.tick_since(start) < time.Duration(ms) * time.Millisecond {
			v, _ := evaluate(r.c, r.page_session, js, quiet = true)
			if b, _ := v.(bool); b == want do return true, ""
			time.sleep(250 * time.Millisecond)
		}
		return false, "timeout"
	case "wait_gw":
		ev, ms := split_timeout(rest, 15000)
		if !wait_gw_from(r, ev, d.gw_cursor[d.cur], ms) do return false, "no gateway event"
		return true, ""
	case "click", "rclick", "hover", "click_last", "hover_last", "rclick_last":
		d.gw_cursor[d.cur] = gw_len(r)
		last := strings.has_suffix(cmd, "_last")
		finder := fmt.tprintf("(()=>{{const l=document.querySelectorAll(%s);return l[l.length-1]}})()", cdp.quote(rest)) if last else fmt.tprintf("document.querySelector(%s)", cdp.quote(rest))
		pt, ok := locate(r, finder)
		if !ok do return false, "element not found"
		move_mouse(d, pt)
		if strings.has_prefix(cmd, "hover") do return true, ""
		click(d, pt, "right" if strings.has_prefix(cmd, "rclick") else "left")
		human(500, 1100)
		return true, ""
	case "click_text", "rclick_text":
		d.gw_cursor[d.cur] = gw_len(r)
		bar := strings.index(rest, " | ")
		if bar < 0 do return false, "syntax: click_text SEL | TEXT"
		sel, text := rest[:bar], rest[bar + 3:]
		finder := fmt.tprintf(
			"(()=>{{const t=%s;return [...document.querySelectorAll(%s)].find(e=>e.textContent.trim()===t||e.getAttribute('aria-label')===t||(e.innerText||'').trim().split('\\n')[0].trim()===t)}})()",
			cdp.quote(text),
			cdp.quote(sel),
		)
		pt, ok := locate(r, finder)
		if !ok do return false, "element with text not found"
		move_mouse(d, pt)
		click(d, pt, "right" if cmd == "rclick_text" else "left")
		human(500, 1100)
		return true, ""
	case "type":
		d.gw_cursor[d.cur] = gw_len(r)
		for ch in rest {
			s := fmt.tprintf("%c", ch)
			kd := fmt.tprintf(`{{"type":"keyDown","text":%s,"unmodifiedText":%s,"key":%s}}`, cdp.quote(s), cdp.quote(s), cdp.quote(s))
			cdp.call(r.c, "Input.dispatchKeyEvent", kd, r.page_session)
			human(20, 50)
			cdp.call(r.c, "Input.dispatchKeyEvent", fmt.tprintf(`{{"type":"keyUp","key":%s}}`, cdp.quote(s)), r.page_session)
			human(60, 170)
		}
		human(300, 700)
		return true, ""
	case "key":
		d.gw_cursor[d.cur] = gw_len(r)
		return key(d, rest)
	case "upload":
		bar := strings.index(rest, " | ")
		if bar < 0 do return false, "syntax: upload SEL | PATH"
		sel, file := rest[:bar], rest[bar + 3:]
		abs, _ := filepath.abs(file, context.temp_allocator)
		doc, ok := cdp.call_value(r.c, "DOM.getDocument", `{"depth":0}`, r.page_session)
		if !ok do return false, "DOM.getDocument"
		root := i64(cdp.num(doc, "root", "nodeId"))
		q, qok := cdp.call_value(r.c, "DOM.querySelector", fmt.tprintf(`{{"nodeId":%d,"selector":%s}}`, root, cdp.quote(sel)), r.page_session)
		node := i64(cdp.num(q, "nodeId"))
		if !qok || node == 0 do return false, "file input not found"
		d.gw_cursor[d.cur] = gw_len(r)
		if _, sok := cdp.call_value(r.c, "DOM.setFileInputFiles", fmt.tprintf(`{{"files":[%s],"nodeId":%d}}`, cdp.quote(abs), node), r.page_session); !sok {
			return false, "setFileInputFiles"
		}
		human(800, 1500)
		return true, ""
	case "scroll":
		bar := strings.index(rest, " | ")
		if bar < 0 do return false, "syntax: scroll SEL | DY"
		sel, dy := rest[:bar], rest[bar + 3:]
		pt, ok := locate(r, fmt.tprintf("document.querySelector(%s)", cdp.quote(sel)))
		if !ok do return false, "element not found"
		move_mouse(d, pt)
		delta, _ := strconv.parse_f64(dy)
		steps := 6
		for _ in 0 ..< steps {
			cdp.call(r.c, "Input.dispatchMouseEvent", fmt.tprintf(`{{"type":"mouseWheel","x":%.1f,"y":%.1f,"deltaX":0,"deltaY":%.1f}}`, pt.x, pt.y, delta / f64(steps)), r.page_session)
			human(30, 70)
		}
		return true, ""
	case "js":
		v, ok := evaluate(r.c, r.page_session, rest)
		fmt.println("  =>", cdp.to_json(v))
		return ok, "js failed"
	}
	return false, "unknown command"
}

@(private)
split_timeout :: proc(rest: string, def: int) -> (string, int) {
	sp := strings.last_index_byte(rest, ' ')
	if sp > 0 {
		if n, ok := strconv.parse_int(rest[sp + 1:]); ok do return strings.trim_space(rest[:sp]), n
	}
	return rest, def
}

@(private)
gw_len :: proc(r: ^Recorder) -> int {
	sync.mutex_lock(&r.mu)
	defer sync.mutex_unlock(&r.mu)
	return len(r.gw_events)
}

@(private)
wait_gw_from :: proc(r: ^Recorder, name: string, from: int, ms: int) -> bool {
	start := time.tick_now()
	for time.tick_since(start) < time.Duration(ms) * time.Millisecond {
		if sync.atomic_load(&r.aborted) do return false
		sync.mutex_lock(&r.mu)
		for i in from ..< len(r.gw_events) {
			e := r.gw_events[i]
			if e.dir == "recv" && e.name == name {
				sync.mutex_unlock(&r.mu)
				return true
			}
		}
		sync.mutex_unlock(&r.mu)
		time.sleep(100 * time.Millisecond)
	}
	return false
}

// settle waits until no account had network activity for quiet_ms (cap max_ms).
@(private)
settle :: proc(d: ^Driver, quiet_ms, max_ms: int) {
	start := time.tick_now()
	for time.tick_since(start) < time.Duration(max_ms) * time.Millisecond {
		if sync.atomic_load(&d.abort) do return
		quiet := true
		now := rt_now(d.out)
		for r in d.accts {
			if r == nil do continue
			sync.mutex_lock(&r.mu)
			if now - r.last_net < f64(quiet_ms) do quiet = false
			sync.mutex_unlock(&r.mu)
		}
		if quiet do return
		time.sleep(200 * time.Millisecond)
	}
}

Point :: [2]f64

// locate scrolls the element into view if needed and returns a point inside it.
@(private)
locate :: proc(r: ^Recorder, finder: string) -> (Point, bool) {
	js := fmt.tprintf(
		`(()=>{{const e=%s;if(!e)return null;let b=e.getBoundingClientRect();` +
		`if(b.top<0||b.bottom>innerHeight||b.left<0||b.right>innerWidth){{e.scrollIntoView({{block:'center'}});b=e.getBoundingClientRect();}}` +
		`return [b.left,b.top,b.width,b.height,innerWidth,innerHeight];}})()`,
		finder,
	)
	for attempt in 0 ..< 40 {
		v, ok := evaluate(r.c, r.page_session, js, quiet = attempt > 0)
		if l, is_list := v.(etf.List); ok && is_list && len(l) == 6 {
			f :: proc(x: etf.Value) -> f64 {
				#partial switch n in x {
				case i64:
					return f64(n)
				case f64:
					return n
				}
				return 0
			}
			x, y, w, h := f(l[0]), f(l[1]), f(l[2]), f(l[3])
			if w > 0 && h > 0 {
				// a point near the centre, jittered like a person would
				px := x + w * (0.5 + (rand.float64() - 0.5) * 0.4)
				py := y + h * (0.5 + (rand.float64() - 0.5) * 0.4)
				return {px, py}, true
			}
		}
		_ = attempt
		time.sleep(250 * time.Millisecond)
	}
	return {}, false
}

@(private)
move_mouse :: proc(d: ^Driver, to: Point) {
	r := cur(d)
	from := d.mouse[d.cur]
	dist := math.sqrt((to.x - from.x) * (to.x - from.x) + (to.y - from.y) * (to.y - from.y))
	steps := clamp(int(dist / 40), 4, 25)
	for i in 1 ..= steps {
		t := f64(i) / f64(steps)
		e := t * t * (3 - 2 * t) // smoothstep
		x := from.x + (to.x - from.x) * e + (rand.float64() - 0.5) * 2
		y := from.y + (to.y - from.y) * e + (rand.float64() - 0.5) * 2
		if i == steps do x, y = to.x, to.y
		cdp.call(r.c, "Input.dispatchMouseEvent", fmt.tprintf(`{{"type":"mouseMoved","x":%.1f,"y":%.1f}}`, x, y), r.page_session)
		human(8, 22)
	}
	d.mouse[d.cur] = to
	human(80, 220)
}

@(private)
click :: proc(d: ^Driver, pt: Point, button: string) {
	r := cur(d)
	cdp.call(r.c, "Input.dispatchMouseEvent", fmt.tprintf(`{{"type":"mousePressed","x":%.1f,"y":%.1f,"button":"%s","clickCount":1}}`, pt.x, pt.y, button), r.page_session)
	human(60, 130)
	cdp.call(r.c, "Input.dispatchMouseEvent", fmt.tprintf(`{{"type":"mouseReleased","x":%.1f,"y":%.1f,"button":"%s","clickCount":1}}`, pt.x, pt.y, button), r.page_session)
}

@(private)
Key_Def :: struct {
	name, code: string,
	vk:         int,
	text:       string,
}

@(private)
KEYS := [?]Key_Def {
	{"Enter", "Enter", 13, "\r"},
	{"Escape", "Escape", 27, ""},
	{"Backspace", "Backspace", 8, ""},
	{"Delete", "Delete", 46, ""},
	{"Tab", "Tab", 9, ""},
	{"ArrowUp", "ArrowUp", 38, ""},
	{"ArrowDown", "ArrowDown", 40, ""},
	{"ArrowLeft", "ArrowLeft", 37, ""},
	{"ArrowRight", "ArrowRight", 39, ""},
	{"a", "KeyA", 65, "a"},
	{"k", "KeyK", 75, "k"},
	{",", "Comma", 188, ","},
}

@(private)
key :: proc(d: ^Driver, rest: string) -> (bool, string) {
	r := cur(d)
	parts := strings.fields(rest, context.temp_allocator)
	if len(parts) == 0 do return false, "no key"
	def: Key_Def
	found := false
	for k in KEYS do if k.name == parts[0] {def = k; found = true}
	if !found do return false, "unknown key"
	mods := 0
	for m in parts[1:] {
		switch m {
		case "alt":
			mods |= 1
		case "ctrl":
			mods |= 2
		case "meta":
			mods |= 4
		case "shift":
			mods |= 8
		}
	}
	text := def.text if mods & 6 == 0 else ""
	// macOS: editing shortcuts only work when the editor command is passed explicitly.
	commands := ""
	if mods == 4 {
		switch def.name {
		case "a":
			commands = `,"commands":["selectAll"]`
		}
	}
	down := fmt.tprintf(
		`{{"type":"%s","key":%s,"code":%s,"windowsVirtualKeyCode":%d,"nativeVirtualKeyCode":%d,"modifiers":%d%s%s}}`,
		"keyDown" if text != "" else "rawKeyDown",
		cdp.quote(def.name),
		cdp.quote(def.code),
		def.vk,
		def.vk,
		mods,
		fmt.tprintf(`,"text":%s,"unmodifiedText":%s`, cdp.quote(text), cdp.quote(text)) if text != "" else "",
		commands,
	)
	cdp.call(r.c, "Input.dispatchKeyEvent", down, r.page_session)
	human(50, 110)
	up := fmt.tprintf(`{{"type":"keyUp","key":%s,"code":%s,"windowsVirtualKeyCode":%d,"nativeVirtualKeyCode":%d,"modifiers":%d}}`, cdp.quote(def.name), cdp.quote(def.code), def.vk, def.vk, mods)
	cdp.call(r.c, "Input.dispatchKeyEvent", up, r.page_session)
	human(400, 900)
	return true, ""
}
