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

Point :: struct { x, y: float64; }

Driver :: struct {
    accts: [2]*Recorder;
    cur: int;
    out: *Out;
    vars: Table(string, string);
    mouse: [2]Point;
    gw_cursor: [2]int;
    failed: bool;
    abort: bool;  // watchdog tripped (atomic)
    name: string;
    done: bool;   // scenario finished (atomic)
}

// f1 formats a coordinate or time like "%.1f".
f1 :: (x: float64) -> FormatFloat #expand { return formatFloat(x, trailing_width = 1, zero_removal = .NO); }

rand01 :: () -> float64 { return random_get_zero_to_one_new(); }

human :: (lo: int, hi: int) {
    sleep_milliseconds(cast(s32) (lo + cast(int) (random_get() % cast(u64) max(hi - lo, 1))));
}

dir_of :: (path: string) -> string {
    found, dir := split_from_right(path, #char "/");
    return ifx found then dir else ".";
}

load_vars :: (d: *Driver, dir: string) {
    data, ok := read_entire_file(join(dir, "/env",, temp), log_errors = false);
    if !ok return;
    for line: split(data, "\n",, temp) {
        l := trim(line);
        if !l || l[0] == #char "#" continue;
        found, k, v := split_from_left(l, #char "=");
        if found table_set(*d.vars, trim(k), trim(v));
    }
}

subst :: (d: *Driver, s: string) -> string {
    out: String_Builder;
    out.allocator = temp;
    i := 0;
    while i < s.count {
        if i + 1 < s.count && s[i] == #char "$" && s[i + 1] == #char "{" {
            end := find_index_from_left(s, #char "}", i) - i;
            if end > 0 {
                name := slice(s, i + 2, end - 2);
                found, v := table_find(*d.vars, name);
                if found append(*out, v);
                else eprint("undefined variable %\n", name);
                i += end + 1;
                continue;
            }
        }
        append(*out, s[i]);
        i += 1;
    }
    return builder_to_string(*out,, temp);
}

run_scenario :: (path: string, out_path: string) -> bool {
    src, ok := read_entire_file(path);
    if !ok {
        eprint("cannot read %\n", path);
        return false;
    }
    name := path_strip_extension(path_filename(path));
    op := ifx out_path then out_path else sprint(".secrets/raw/%.jsonl", name);
    if !contains(op, ".secrets/") {
        eprint("raw output must go under .secrets/\n");
        return false;
    }
    random_seed(cast(u64) to_nanoseconds(current_time_consensus()));
    d: Driver;
    d.name = name;
    load_vars(*d, dir_of(path));
    lines := expand_includes(src, dir_of(path));
    uses_b := false;
    for lines if trim(it) == "use b" uses_b = true;

    if !check_test_instance(PORT_A) return false;
    if uses_b && !check_test_instance(PORT_B) return false;
    out, ook := out_open(op);
    if !ook return false;
    d.out = out;
    defer out_close(out);
    // Whatever happens below, undo everything on the instances (detach, disable domains).
    defer for d.accts if it recorder_stop(it);
    aok, bok: bool;
    d.accts[0], aok = recorder_start("a", PORT_A, out);
    if !aok return false;
    if uses_b {
        d.accts[1], bok = recorder_start("b", PORT_B, out);
        if !bok return false;
    }
    // watchdog: checks every recording page's JS heap while the scenario runs
    wd := New(Thread);
    thread_init(wd, (t: *Thread) -> s64 {
        d := cast(*Driver) t.data;
        while !atomic_load(*d.done) {
            for 1..25 {
                if atomic_load(*d.done) return 0;
                sleep_milliseconds(200);
            }
            for d.accts if it && !heap_check(it) atomic_store(*d.abort, true);
        }
        return 0;
    });
    wd.data = *d;
    thread_start(wd);
    // FC_VIDEO=1: grab ~15 JPEG frames a second of each page for the site's side-by-side videos,
    // named by the recording's clock (rt_now) so they line up with the traffic.
    vt: *Thread;
    if getenv("FC_VIDEO") {
        vt = New(Thread);
        thread_init(vt, (t: *Thread) -> s64 {
            d := cast(*Driver) t.data;
            while !atomic_load(*d.done) {
                start := current_time_monotonic();
                for d.accts if it {
                    shot, ok := cdp.call_value(it.c, "Page.captureScreenshot", "{\"format\":\"jpeg\",\"quality\":70}", it.page_session, 2_000);
                    if ok write_entire_file(tprint("%/%/video/%_%.jpg", SCREENS_DIR, d.name, it.acct, cast(int) rt_now(d.out)), base64_decode(cdp.str(shot, "data"),, temp));
                }
                reset_temporary_storage();
                left := 66 - to_milliseconds(current_time_monotonic() - start);
                if left > 0 sleep_milliseconds(xx left);
            }
            return 0;
        });
        vt.data = *d;
        make_directory_if_it_does_not_exist(tprint("%/%/video", SCREENS_DIR, name), recursive = true);
        thread_start(vt);
    }
    defer {
        atomic_store(*d.done, true);
        locks.join(wd);
        if vt locks.join(vt);
    }
    scenario_start := current_time_monotonic();
    // The test windows are usually behind other windows; make the page behave as focused
    // (a real user has the window focused while acting).
    for d.accts if it cdp.call_value(it.c, "Emulation.setFocusEmulationEnabled", "{\"enabled\":true}", it.page_session);
    for *d.mouse it.* = .{400 + rand01() * 200, 300 + rand01() * 100};
    out_line(out, "a", tprint("\"note\":%", cdp.quote(tprint("scenario %", name))));
    sleep_milliseconds(1500);  // let attach + Network.enable settle

    for raw_line, ln: lines {
        if atomic_load(*d.abort) {
            eprint("aborted by watchdog\n");
            d.failed = true;
            break;
        }
        if to_milliseconds(current_time_monotonic() - scenario_start) > MAX_CAPTURE_SECONDS * 1000 {
            eprint("scenario exceeded the time cap; aborting\n");
            d.failed = true;
            break;
        }
        line := trim(raw_line);
        if !line || line[0] == #char "#" continue;
        line = subst(*d, line);
        optional := begins_with(line, "optional ");
        if optional line = trim(slice(line, 9, line.count - 9));
        print("[%:%] %\n", name, ln + 1, line);
        ok, msg := exec(*d, line);
        if !ok {
            note := tprint("line % `%` failed: %", ln + 1, line, msg);
            eprint("%\n", note);
            out_line(out, d.accts[d.cur].acct, tprint("\"note\":%", cdp.quote(note)));
            if !optional {
                d.failed = true;
                break;
            }
        }
        reset_temporary_storage();
    }
    if !atomic_load(*d.abort) settle(*d, 2000, 15000);
    for d.accts if it print("%: peak JS heap % MB\n", it.acct, formatFloat(it.heap_peak / (1 << 20), trailing_width = 0));
    print("% -> % (%)\n", name, op, ifx d.failed then "FAILED" else "ok");
    return !d.failed;
}

// expand_includes inlines `include FILE` lines (path relative to the scenario dir).
expand_includes :: (src: string, dir: string, depth := 0) -> []string {
    out: [..]string;
    for line: split(src, "\n") {
        l := trim(line);
        if begins_with(l, "include ") && depth < 8 {
            inc := trim(slice(l, 8, l.count - 8));
            p := ifx begins_with(inc, "/") then inc else join(dir, "/", inc);
            data, ok := read_entire_file(p, log_errors = false);
            if !ok {
                eprint("cannot include %\n", p);
                array_add(*out, "fail_include");
                continue;
            }
            array_add(*out, ..expand_includes(data, dir, depth + 1));
            continue;
        }
        array_add(*out, trim_right(line, "\r"));
    }
    return out;
}

split_cmd :: (line: string) -> cmd: string, rest: string {
    found, cmd, rest := split_from_left(line, #char " ");
    return cmd, trim(rest);
}

// split_bar splits "A | B".
split_bar :: (rest: string) -> bool, string, string {
    found, a, b := split_from_left(rest, " | ");
    return found, a, b;
}

cur :: (d: *Driver) -> *Recorder { return d.accts[d.cur]; }

exec :: (d: *Driver, line: string) -> bool, string {
    cmd, rest := split_cmd(line);
    r := cur(d);
    if cmd == {
      case "use";
        idx := ifx rest == "b" then 1 else 0;
        if !d.accts[idx] return false, "account not recording";
        d.cur = idx;
      case "mark";
        for d.accts if it out_line(d.out, it.acct, tprint("\"mark\":%", cdp.quote(rest)));
        snap(d, rest);
      case "snap";
        if !snap(d, rest) return false, "snap failed";
      case "probe";
        found, pname, file := split_bar(rest);
        if !found return false, "syntax: probe NAME | FILE.js";
        src, ok := read_entire_file(file,, temp);
        if !ok return false, "cannot read probe";
        v, eok := evaluate(r.c, r.page_session, src);
        if !eok return false, "probe failed";
        path := screen_path(d, pname, "json");
        write_entire_file(path, ifx v.kind == .String then v.s else "");
        print("  probe -> %\n", path);
      case "wait";
        start := current_time_monotonic();
        while to_milliseconds(current_time_monotonic() - start) < string_to_int(rest) {
            if atomic_load(*d.abort) return false, "aborted";
            sleep_milliseconds(100);
        }
      case "pause";
        human(700, 1600);
      case "settle";
        ms := string_to_int(rest);
        settle(d, ifx ms > 0 then ms else 1500, 20000);
      case "reload";
        start: int;
        {
            locks.guard(*r.mu);
            start = r.gw_events.count;
        }
        _, ok := cdp.call_value(r.c, "Page.reload", "{\"ignoreCache\":false}", r.page_session);
        if !ok return false, "Page.reload";
        if !wait_gw_from(r, "READY", start, 45000) return false, "no READY after reload";
        settle(d, 2500, 30000);
      case "wait_for"; #through;
      case "wait_gone";
        sel, ms := split_timeout(rest, 15000);
        js := tprint("!!document.querySelector(%)", cdp.quote(sel));
        want := cmd == "wait_for";
        start := current_time_monotonic();
        while to_milliseconds(current_time_monotonic() - start) < ms {
            v := evaluate(r.c, r.page_session, js, quiet = true);
            if (v.kind == .Bool && v.b) == want return true, "";
            sleep_milliseconds(250);
        }
        return false, "timeout";
      case "wait_gw";
        ev, ms := split_timeout(rest, 15000);
        if !wait_gw_from(r, ev, d.gw_cursor[d.cur], ms) return false, "no gateway event";
      case "click"; #through;
      case "rclick"; #through;
      case "hover"; #through;
      case "click_last"; #through;
      case "hover_last"; #through;
      case "rclick_last";
        d.gw_cursor[d.cur] = gw_len(r);
        finder := ifx ends_with(cmd, "_last")
            then tprint("(()=>{const l=document.querySelectorAll(%);return l[l.length-1]})()", cdp.quote(rest))
            else tprint("document.querySelector(%)", cdp.quote(rest));
        pt, ok := locate(r, finder);
        if !ok return false, "element not found";
        move_mouse(d, pt);
        if begins_with(cmd, "hover") return true, "";
        click(d, pt, ifx begins_with(cmd, "rclick") then "right" else "left");
        human(500, 1100);
      case "click_text"; #through;
      case "rclick_text";
        d.gw_cursor[d.cur] = gw_len(r);
        found, sel, text := split_bar(rest);
        if !found return false, "syntax: click_text SEL | TEXT";
        finder := tprint("(()=>{const ts=%.split(' || ');return [...document.querySelectorAll(%)].find(e=>ts.some(t=>e.textContent.trim()===t||e.getAttribute('aria-label')===t||(e.innerText||'').trim().split('\\n')[0].trim()===t))})()",
            cdp.quote(text), cdp.quote(sel));
        pt, ok := locate(r, finder);
        if !ok return false, "element with text not found";
        move_mouse(d, pt);
        click(d, pt, ifx cmd == "rclick_text" then "right" else "left");
        human(500, 1100);
      case "type";
        d.gw_cursor[d.cur] = gw_len(r);
        i := 0;
        while i < rest.count {
            // one UTF-8 character per key event
            c := rest[i];
            n := ifx c < 0xC0 then 1 else ifx c < 0xE0 then 2 else ifx c < 0xF0 then 3 else 4;
            s := cdp.quote(slice(rest, i, min(n, rest.count - i)));
            i += n;
            cdp.call(r.c, "Input.dispatchKeyEvent", tprint("{\"type\":\"keyDown\",\"text\":%1,\"unmodifiedText\":%1,\"key\":%1}", s), r.page_session);
            human(20, 50);
            cdp.call(r.c, "Input.dispatchKeyEvent", tprint("{\"type\":\"keyUp\",\"key\":%}", s), r.page_session);
            human(60, 170);
        }
        human(300, 700);
      case "key";
        d.gw_cursor[d.cur] = gw_len(r);
        ok, msg := key(d, rest);
        return ok, msg;
      case "upload";
        found, sel, file := split_bar(rest);
        if !found return false, "syntax: upload SEL | PATH";
        full := get_absolute_path(file);
        doc, ok := cdp.call_value(r.c, "DOM.getDocument", "{\"depth\":0}", r.page_session);
        if !ok return false, "DOM.getDocument";
        root := cast(s64) cdp.num(doc, "root", "nodeId");
        q, qok := cdp.call_value(r.c, "DOM.querySelector", tprint("{\"nodeId\":%,\"selector\":%}", root, cdp.quote(sel)), r.page_session);
        node := cast(s64) cdp.num(q, "nodeId");
        if !qok || node == 0 return false, "file input not found";
        d.gw_cursor[d.cur] = gw_len(r);
        _, sok := cdp.call_value(r.c, "DOM.setFileInputFiles", tprint("{\"files\":[%],\"nodeId\":%}", cdp.quote(full), node), r.page_session);
        if !sok return false, "setFileInputFiles";
        human(800, 1500);
      case "scroll";
        found, sel, dy := split_bar(rest);
        if !found return false, "syntax: scroll SEL | DY";
        pt, ok := locate(r, tprint("document.querySelector(%)", cdp.quote(sel)));
        if !ok return false, "element not found";
        move_mouse(d, pt);
        STEPS :: 6;
        step := string_to_float64(dy) / STEPS;
        for 1..STEPS {
            cdp.call(r.c, "Input.dispatchMouseEvent", tprint("{\"type\":\"mouseWheel\",\"x\":%,\"y\":%,\"deltaX\":0,\"deltaY\":%}", f1(pt.x), f1(pt.y), f1(step)), r.page_session);
            human(30, 70);
        }
      case "let";
        vname, expr := split_cmd(rest);
        v, ok := evaluate(r.c, r.page_session, expr);
        if !ok || v.kind != .String || !v.s return false, "let: no string result";
        table_set(*d.vars, copy_string(vname), copy_string(v.s));
        print("  let %\n", vname);
      case "js";
        v, ok := evaluate(r.c, r.page_session, rest);
        print("  => %\n", cdp.to_json(v));
        return ok, "js failed";
      case;
        return false, "unknown command";
    }
    return true, "";
}

SCREENS_DIR :: "/Users/creikey/Documents/fastcord/.secrets/screens";

screen_path :: (d: *Driver, name: string, ext: string) -> string {
    dir := tprint("%/%", SCREENS_DIR, d.name);
    make_directory_if_it_does_not_exist(dir, recursive = true);
    safe := replace(name, "/", "_",, temp);
    return tprint("%/%%.%", dir, safe, ifx d.cur == 0 then "" else ".b", ext);
}

probe_source :: (rel: string) -> string {
    s, ok := read_entire_file(join(#filepath, rel));
    assert(ok, "missing probe %", rel);
    return s;
}
LAYOUT_JS :: #run probe_source("../../tools/capture/probes/layout.js");
LAYOUT_GEOMETRY_JS :: #run probe_source("../../tools/probes/layout_geometry.js");

// snap saves a screenshot and a layout dump of the current account's page.
// Screens show other people's content: they stay in .secrets/screens.
snap :: (d: *Driver, name: string) -> bool {
    r := cur(d);
    shot, ok := cdp.call_value(r.c, "Page.captureScreenshot", "{\"format\":\"png\"}", r.page_session, 15_000);
    if !ok return false;
    write_entire_file(screen_path(d, name, "png"), base64_decode(cdp.str(shot, "data"),, temp));
    layout := evaluate(r.c, r.page_session, LAYOUT_JS, quiet = true);
    geometry := evaluate(r.c, r.page_session, LAYOUT_GEOMETRY_JS, quiet = true);
    ls := ifx layout.kind == .String && layout.s then layout.s else "null";
    gs := ifx geometry.kind == .String then geometry.s else "";
    write_entire_file(screen_path(d, name, "json"), tprint("{\"layout\":%,\"geometry\":%}", ls, cdp.quote(gs)));
    return true;
}

split_timeout :: (rest: string, def: int) -> string, int {
    sp := find_index_from_right(rest, #char " ");
    if sp > 0 {
        n, ok, tail := string_to_int(slice(rest, sp + 1, rest.count - sp - 1));
        if ok && !tail return trim(slice(rest, 0, sp)), n;
    }
    return rest, def;
}

gw_len :: (r: *Recorder) -> int {
    locks.guard(*r.mu);
    return r.gw_events.count;
}

wait_gw_from :: (r: *Recorder, name: string, from: int, ms: int) -> bool {
    start := current_time_monotonic();
    while to_milliseconds(current_time_monotonic() - start) < ms {
        if atomic_load(*r.aborted) return false;
        {
            locks.guard(*r.mu);
            for i: from..r.gw_events.count-1 {
                e := r.gw_events[i];
                if e.dir == "recv" && e.name == name return true;
            }
        }
        sleep_milliseconds(100);
    }
    return false;
}

// settle waits until no account had network activity for quiet_ms (cap max_ms).
settle :: (d: *Driver, quiet_ms: int, max_ms: int) {
    start := current_time_monotonic();
    while to_milliseconds(current_time_monotonic() - start) < max_ms {
        if atomic_load(*d.abort) return;
        quiet := true;
        now := rt_now(d.out);
        for d.accts if it {
            locks.guard(*it.mu);
            if now - it.last_net < cast(float64) quiet_ms quiet = false;
        }
        if quiet return;
        sleep_milliseconds(200);
    }
}

// locate scrolls the element into view if needed and returns a point inside it.
locate :: (r: *Recorder, finder: string) -> Point, bool {
    js := join("(()=>{const e=", finder, ";if(!e)return null;let b=e.getBoundingClientRect();",
        "if(b.top<0||b.bottom>innerHeight||b.left<0||b.right>innerWidth){e.scrollIntoView({block:'center'});b=e.getBoundingClientRect();}",
        "return [b.left,b.top,b.width,b.height,innerWidth,innerHeight];})()",, temp);
    f :: (x: etf.Value) -> float64 {
        if x.kind == .Int   return cast(float64) x.i;
        if x.kind == .Float return x.f;
        return 0;
    }
    for attempt: 0..39 {
        v, ok := evaluate(r.c, r.page_session, js, quiet = attempt > 0);
        if ok && v.kind == .List && v.list.count == 6 {
            l := v.list;
            x, y, w, h := f(l[0]), f(l[1]), f(l[2]), f(l[3]);
            // a point near the centre, jittered like a person would
            if w > 0 && h > 0 return .{x + w * (0.5 + (rand01() - 0.5) * 0.4), y + h * (0.5 + (rand01() - 0.5) * 0.4)}, true;
        }
        sleep_milliseconds(250);
    }
    return .{}, false;
}

move_mouse :: (d: *Driver, to: Point) {
    r := cur(d);
    from := d.mouse[d.cur];
    dist := sqrt((to.x - from.x) * (to.x - from.x) + (to.y - from.y) * (to.y - from.y));
    steps := clamp(cast(int) (dist / 40), 4, 25);
    for i: 1..steps {
        t := cast(float64) i / steps;
        e := t * t * (3 - 2 * t);  // smoothstep
        x := from.x + (to.x - from.x) * e + (rand01() - 0.5) * 2;
        y := from.y + (to.y - from.y) * e + (rand01() - 0.5) * 2;
        if i == steps x, y = to.x, to.y;
        cdp.call(r.c, "Input.dispatchMouseEvent", tprint("{\"type\":\"mouseMoved\",\"x\":%,\"y\":%}", f1(x), f1(y)), r.page_session);
        human(8, 22);
    }
    d.mouse[d.cur] = to;
    human(80, 220);
}

click :: (d: *Driver, pt: Point, button: string) {
    r := cur(d);
    for type: string.["mousePressed", "mouseReleased"] {
        if it_index human(60, 130);
        cdp.call(r.c, "Input.dispatchMouseEvent", tprint("{\"type\":\"%\",\"x\":%,\"y\":%,\"button\":\"%\",\"clickCount\":1}", type, f1(pt.x), f1(pt.y), button), r.page_session);
    }
}

Key_Def :: struct {
    name, code: string;
    vk: int;
    text: string;
}

KEYS :: Key_Def.[
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
    .{"v", "KeyV", 86, "v"},
];

key :: (d: *Driver, rest: string) -> bool, string {
    r := cur(d);
    parts := fields(rest);
    if !parts.count return false, "no key";
    def: Key_Def;
    for KEYS if it.name == parts[0] def = it;
    if !def.name return false, "unknown key";
    mods := 0;
    for m: array_view(parts, 1, parts.count - 1) {
        if m == "alt"   mods |= 1;
        if m == "ctrl"  mods |= 2;
        if m == "meta"  mods |= 4;
        if m == "shift" mods |= 8;
    }
    text := ifx (mods & 6) == 0 then def.text else "";
    // macOS: editing shortcuts only work when the editor command is passed explicitly.
    commands := "";
    if mods == 4 && def.name == "a" commands = ",\"commands\":[\"selectAll\"]";
    if mods == 4 && def.name == "v" commands = ",\"commands\":[\"paste\"]";
    common := tprint("\"key\":%,\"code\":%,\"windowsVirtualKeyCode\":%3,\"nativeVirtualKeyCode\":%3,\"modifiers\":%4",
        cdp.quote(def.name), cdp.quote(def.code), def.vk, mods);
    down := tprint("{\"type\":\"%\",%%%}", ifx text then "keyDown" else "rawKeyDown", common,
        ifx text then tprint(",\"text\":%1,\"unmodifiedText\":%1", cdp.quote(text)) else "", commands);
    cdp.call(r.c, "Input.dispatchKeyEvent", down, r.page_session);
    human(50, 110);
    cdp.call(r.c, "Input.dispatchKeyEvent", tprint("{\"type\":\"keyUp\",%}", common), r.page_session);
    human(400, 900);
    return true, "";
}
