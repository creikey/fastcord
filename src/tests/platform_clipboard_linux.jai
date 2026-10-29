// Synthetic X11 selections only: never owns or requests the desktop CLIPBOARD/PRIMARY.
// jai build.jai - run src/tests/platform_clipboard_linux.jai && build/platform_clipboard_linux
#import "Basic";
#import "Math";
#import "String";
#import "Atomics";
#import "Thread";
#import "Flat_Pool";
#import "Unicode";
#import "File";
locks :: #import "locks";
#load "../platform/platform.jai";
#load "../platform/instance.jai";
#load "../platform/wayland_linux.jai";
#assert OS == .LINUX;

// #load module.jai keeps X/xs file-private. Expose only their visibility in this test;
// all behavior still comes directly from the production source, not a copied implementation.
#insert #run clipboard_test_source();
clipboard_test_source :: () -> string {
    source, ok := read_entire_file("src/platform/platform_linux.jai");
    assert(ok);
    visible, count := replace(source, "#scope_file", "#scope_module");
    assert(count > 0);
    return visible;
}

failures := 0;
expect :: (ok: bool, what: string) {
    print("%: %\n", ifx ok then "PASS" else "FAIL", what);
    if !ok failures += 1;
}

Owner :: struct {
    d: *void;
    win: Window;
    target, type: Atom;
    text: string;
    stop: bool; // atomic; the remaining fields are immutable while the thread runs
}

owner_proc :: (t: *Thread) -> s64 {
    o := cast(*Owner) t.data;
    deadline := time_now() + 10;
    while !atomic_load(*o.stop) && time_now() < deadline {
        ev: XEvent;
        while X.Pending(o.d) > 0 {
            X.NextEvent(o.d, *ev);
            if ev.type != SelectionRequest continue;
            r := ev.xselectionrequest;
            reply: XEvent;
            reply.xselection = .{type = SelectionNotify, requestor = r.requestor,
                selection = r.selection, target = r.target, time = r.time};
            prop := ifx r.property then r.property else r.target;
            if r.selection == xs.a.CLIPBOARD {
                if r.target == xs.a.TARGETS {
                    targets := Atom.[xs.a.TARGETS, o.target];
                    X.ChangeProperty(o.d, r.requestor, prop, XA_ATOM, 32, 0, xx targets.data, targets.count);
                    reply.xselection.property = prop;
                } else if r.target == o.target {
                    X.ChangeProperty(o.d, r.requestor, prop, o.type, 8, 0, o.text.data, xx o.text.count);
                    reply.xselection.property = prop;
                }
            }
            X.SendEvent(o.d, r.requestor, 0, 0, *reply);
            X.Flush(o.d);
        }
        sleep_milliseconds(1);
    }
    return 0;
}

paste_case :: (o: *Owner, name: string, target: Atom, type: Atom, bytes: string, wanted: string) {
    o.target, o.type, o.text, o.stop = target, type, bytes, false;
    X.SetSelectionOwner(o.d, xs.a.CLIPBOARD, o.win, 0);
    expect(X.GetSelectionOwner(o.d, xs.a.CLIPBOARD) == o.win, tprint("% owns private selection", name));
    thread: Thread;
    thread_init(*thread, owner_proc);
    thread.data = o;
    thread_start(*thread);
    defer {
        atomic_store(*o.stop, true);
        thread_is_done(*thread, -1);
        thread_deinit(*thread);
    }
    kind := os_clipboard_kind();
    got := os_clipboard_get(context.allocator);
    defer free(got.data);
    print("  %: kind=%, bytes=% (wanted % UTF-8 bytes)\n", name, kind, got.count, wanted.count);
    expect(kind == .Text, tprint("% classified Text", name));
    expect(got == wanted, tprint("% pasted exact synthetic text", name));
}

// A second X client requests the actual copy responder, driven without the app's window/event loop.
copy_request :: (o: *Owner, target: Atom) -> [..]u8, Atom {
    ev: XEvent;
    while X.Pending(o.d) > 0 X.NextEvent(o.d, *ev);
    X.ConvertSelection(o.d, xs.a.CLIPBOARD, target, xs.a.FC_SELECTION, o.win, 0);
    X.Flush(o.d);
    deadline := time_now() + 2;
    while time_now() < deadline {
        while X.CheckTypedWindowEvent(xs.d, xs.win, SelectionRequest, *ev) answer_selection(*ev.xselectionrequest);
        if X.CheckTypedWindowEvent(o.d, o.win, SelectionNotify, *ev) {
            out: [..]u8;
            if !ev.xselection.property return out, 0;
            type := get_property(o.d, o.win, ev.xselection.property, *out, delete = true);
            return out, type;
        }
        sleep_milliseconds(1);
    }
    empty: [..]u8;
    return empty, 0;
}

// Substitute only keymap lookup: exercise production key-down/up mapping without
// changing the desktop's keymap. Group 1 moves C/V away from their US positions.
layout_symbol :: (code: u8, group: u32) -> u64 #c_call {
    if group == 0 {
        if code == 24 return #char "q";
        if code == 25 return #char "w";
        if code == 54 return #char "c";
        if code == 55 return #char "v";
    } else {
        if code == 24 return #char "v";
        if code == 25 return #char "c";
        if code == 54 return #char "x";
        if code == 55 return 0x07eb; // Greek lambda, not a Latin shortcut
    }
    if code == 61 return #char "/";
    return 0;
}

layout_key :: (code: u32, state: u32, want: Key, name: string) {
    for s32.[KeyPress, KeyRelease] {
        ev: XEvent;
        ev.xkey = .{type = it, display = xs.d, window = xs.win, state = state, keycode = code};
        handle(*ev);
        swap_queues();
        e := events();
        kind := ifx it == KeyPress then Event_Kind.Key_Down else Event_Kind.Key_Up;
        expect(e.count == 1 && e[0].kind == kind && e[0].key == want && e[0].mods == mods_of(state),
            tprint("% (%)", name, kind));
    }
}

layout_lookup_state: u32;
layout_keys :: () {
    lookup := X.kbLookupKeySym;
    defer X.kbLookupKeySym = lookup;
    X.kbLookupKeySym = (d: *void, code: u8, state: u32, consumed: *u32, sym: *u64) -> s32 #c_call {
        layout_lookup_state = state;
        consumed.* = 0;
        sym.* = layout_symbol(code, (state >> 13) & 3);
        if code == 61 && (state & 1) sym.* = #char "?";
        if code == 250 { sym.* = #char "v"; return 0; } // failed lookup must not use the output
        return cast(s32) (ifx sym.* then 1 else 0);
    };
    layout_key(24, 4, .Q, "base group keeps logical Q");
    layout_key(24, 4 | (1 << 13), .V, "active group moves paste to physical Q");
    layout_key(25, 4 | (1 << 13), .C, "active group moves copy to physical W");
    layout_key(54, 4 | (1 << 13), .X, "old physical C is now logical cut");
    layout_key(55, 4 | (1 << 13), .None, "non-Latin symbol does not fall back to physical V");
    layout_key(24, 7 | (1 << 13), .V, "Shift and Caps Lock preserve logical paste");
    layout_key(61, 5 | (1 << 13), .Slash, "shifted punctuation keeps unshifted shortcut");
    layout_key(24, 4 | 0x80 | 0x10 | (3 << 13), .V, "Mod5, NumLock and both group bits reach lookup");
    expect(layout_lookup_state == (4 | 0x80 | 0x10 | (3 << 13)), "lookup preserves Ctrl, Mod5, NumLock and group bits");
    layout_key(250, 4, .None, "failed lookup produces no shortcut");
    layout_key(55, 4, .V, "switching back restores base-group paste");
}

run :: () {
    xs.lib = dlopen("libX11.so.6", RTLD_NOW);
    if !xs.lib || !load_syms(xs.lib, *X, "X") { print("FAIL: libX11 unavailable\n"); exit(2); }
    if !X.InitThreads() { print("FAIL: XInitThreads\n"); exit(2); }
    xs.d = X.OpenDisplay(null);
    xs.clip_d = X.OpenDisplay(null);
    owner: Owner;
    owner.d = X.OpenDisplay(null);
    if !xs.d || !xs.clip_d || !owner.d { print("FAIL: requires an X11 display\n"); exit(2); }
    defer {
        free(xs.own_text.data);
        X.DestroyWindow(owner.d, owner.win);
        X.DestroyWindow(xs.clip_d, xs.clip_win);
        X.DestroyWindow(xs.d, xs.win);
        X.CloseDisplay(owner.d);
        X.CloseDisplay(xs.clip_d);
        X.CloseDisplay(xs.d);
    }
    for type_info(Atoms).members {
        name := ifx it_index < ATOMS_NAMED then it.name else ATOM_NAMES[it_index - ATOMS_NAMED];
        (cast(*Atom) *xs.a)[it_index] = X.InternAtom(xs.d, temp_c_string(name), 0);
    }
    // All clipboard code below uses only this process-unique, private atom.
    xs.a.CLIPBOARD = X.InternAtom(xs.d, temp_c_string(tprint("_FASTCORD_CLIPBOARD_TEST_%_%", getpid(), to_nanoseconds(current_time_monotonic()))), 0);
    xs.win = X.CreateSimpleWindow(xs.d, X.DefaultRootWindow(xs.d), 0, 0, 1, 1, 0, 0, 0);
    xs.clip_win = X.CreateSimpleWindow(xs.clip_d, X.DefaultRootWindow(xs.clip_d), 0, 0, 1, 1, 0, 0, 0);
    owner.win = X.CreateSimpleWindow(owner.d, X.DefaultRootWindow(owner.d), 0, 0, 1, 1, 0, 0, 0);
    X.SelectInput(xs.clip_d, xs.clip_win, PropertyChangeMask);
    X.SelectInput(owner.d, owner.win, PropertyChangeMask);
    X.Flush(xs.d);
    X.Flush(xs.clip_d);
    X.Flush(owner.d);
    s.time_base = current_time_monotonic();

    paste_case(*owner, "UTF8_STRING", xs.a.UTF8_STRING, xs.a.UTF8_STRING, "synthetic café λ", "synthetic café λ");
    paste_case(*owner, "text/plain UTF-8", xs.a.text_plain, xs.a.text_plain, "synthetic plain", "synthetic plain");
    paste_case(*owner, "STRING ASCII", XA_STRING, XA_STRING, "synthetic ASCII", "synthetic ASCII");
    paste_case(*owner, "STRING Latin-1", XA_STRING, XA_STRING, "caf\xe9", "café");
    paste_case(*owner, "TEXT returning UTF8_STRING", xs.a.TEXT, xs.a.UTF8_STRING, "synthetic café", "synthetic café");
    paste_case(*owner, "TEXT returning STRING Latin-1", xs.a.TEXT, XA_STRING, "caf\xe9", "café");
    paste_case(*owner, "empty UTF8_STRING", xs.a.UTF8_STRING, xs.a.UTF8_STRING, "", "");
    // paste_case has stopped and joined its owner thread before returning.
    X.SetSelectionOwner(owner.d, xs.a.CLIPBOARD, 0, 0);
    expect(X.GetSelectionOwner(owner.d, xs.a.CLIPBOARD) == 0, "private selection has no owner");
    expect(os_clipboard_kind() == .None, "unowned private selection classified None");
    unowned := os_clipboard_get(context.allocator);
    expect(unowned == "", "unowned private selection pastes empty text");
    free(unowned.data);

    copied := "synthetic copied café λ";
    os_clipboard_set(copied);
    expect(X.GetSelectionOwner(xs.d, xs.a.CLIPBOARD) == xs.win, "copy owns private selection");
    expect(os_clipboard_kind() == .Text, "own copy classified Text");
    own := os_clipboard_get(context.allocator);
    expect(own == copied, "own copy read back");
    free(own.data);
    {
        b, type := copy_request(*owner, xs.a.TARGETS);
        defer array_free(b);
        targets := []Atom.{b.count / 8, cast(*Atom) b.data};
        expect(type == XA_ATOM && array_find(targets, xs.a.UTF8_STRING)
            && array_find(targets, xs.a.text_plain) && array_find(targets, xs.a.TEXT), "copy advertises text targets");
    }
    for Atom.[xs.a.UTF8_STRING, xs.a.text_plain, xs.a.TEXT] {
        b, type := copy_request(*owner, it);
        expect(type == (ifx it == xs.a.TEXT then xs.a.UTF8_STRING else it)
            && string.{b.count, b.data} == copied, tprint("copy serves target %", it));
        array_free(b);
    }
    // Real X keymap lookup, but no injected desktop keystrokes or input-method/window setup.
    keycode_for := cast((d: *void, sym: u64) -> u8 #c_call) dlsym(xs.lib, "XKeysymToKeycode");
    for u64.[#char "v", #char "c"] {
        k := XKeyEvent.{display = xs.d, window = xs.win, state = 4, keycode = keycode_for(xs.d, it)};
        key_press(*k);
        swap_queues();
        e := events();
        want := ifx it == #char "v" then Key.V else Key.C;
        expect(e.count == 1 && e[0].kind == .Key_Down && e[0].key == want && e[0].mods == .Ctrl,
            tprint("synthetic Ctrl+% maps to Key_Down with Ctrl", want));
    }
    // Read-only integration check against a real secondary group, when configured.
    symbol_for := cast((d: *void, code: u8, group: s32, level: s32) -> u64 #c_call) dlsym(xs.lib, "XkbKeycodeToKeysym");
    checked_group := false;
    for code: 8..255 {
        base := symbol_for(xs.d, cast(u8) code, 0, 0);
        sym := symbol_for(xs.d, cast(u8) code, 1, 0);
        if !sym || sym == base || map_keysym(sym) == .None continue;
        consumed: u32;
        actual: u64;
        if !X.kbLookupKeySym(xs.d, cast(u8) code, 4 | (1 << 13), *consumed, *actual) || actual != sym continue;
        layout_key(cast(u32) code, 4 | (1 << 13), map_keysym(sym), "real XKB secondary group matches logical symbol");
        checked_group = true;
        break;
    }
    if !checked_group print("SKIP: no distinct supported symbol in a real secondary XKB group\n");
    layout_keys();
    array_free(s.pending);
    array_free(s.current);
    fini(*s.pending_pool);
    fini(*s.current_pool);
    print("platform_clipboard_linux: % failure(s)\n", failures);
}

main :: () {
    run();
    if failures exit(1);
}
