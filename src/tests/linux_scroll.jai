// Offline XI2 decoder/event and Wayland-axis regressions. No display connection or input capture.
// jai build.jai - run src/tests/linux_scroll.jai && build/linux_scroll
#load "../platform/module.jai";
ui :: #import "ui";
a :: #import "app";
p :: #import "platform";

near :: (got: float32, want: float32) { assert(abs(got - want) < 0.0001, "got %, want %", got, want); }

scroll_count :: (precise: bool) -> int {
    n := 0;
    for s.pending if it.kind == .Scroll && it.precise == precise n += 1;
    return n;
}

main :: () {
    axes: [..]XI_Scroll_Axis;
    defer array_free(axes);
    c := XIScrollClassInfo.{type = 3, sourceid = 10, number = 3, scroll_type = 1, increment = 120};
    xi_scroll_class(*axes, *c);
    c.number, c.scroll_type, c.increment = 10, 2, -240;
    xi_scroll_class(*axes, *c);
    assert(axes.count == 2);
    // Scroll classes with invalid increments are not handled (and must not suppress legacy wheels).
    c.sourceid, c.increment = 99, 0;
    xi_scroll_class(*axes, *c);
    assert(axes.count == 2);
    // Sparse mask: packed values include unrelated axis 0 and axis 8 before the horizontal axis 10.
    mask := u8.[9, 5];
    values := float64.[999, 1000000000, 777, 2000000000];
    v := XIValuatorState.{mask_len = mask.count, mask = mask.data, values = values.data};
    d := xi_scroll_delta(axes, 10, v);
    near(d.x, 0); near(d.y, 0); // first sample is baseline only
    values[1] += 0.75;
    values[3] += 1.5;
    d = xi_scroll_delta(axes, 10, v);
    near(d.x, 0.33125); near(d.y, -0.33125);
    d = xi_scroll_delta(axes, 10, v);
    near(d.x, 0); near(d.y, 0); // unchanged cumulative values do not repeat a scroll
    d = xi_scroll_delta(axes, 11, v);
    near(d.x, 0); near(d.y, 0); // another source cannot change these baselines
    // A missing axis leaves its baseline intact, and axis 10 still uses packed value 0.
    sparse := u8.[0, 4];
    horizontal := float64.[values[3] + 0.5];
    sv := XIValuatorState.{mask_len = sparse.count, mask = sparse.data, values = horizontal.data};
    d = xi_scroll_delta(axes, 10, sv);
    near(d.x, 53.0 / 480); near(d.y, 0);
    xi_scroll_reset(axes); // return from scrolling outside, or a changed device
    values[1], values[3] = 500, -400;
    d = xi_scroll_delta(axes, 10, v);
    near(d.x, 0); near(d.y, 0);
    values[1] += 0.125;
    d = xi_scroll_delta(axes, 10, v);
    near(d.y, -53.0 / 960);
    // Preferred axis replaces a duplicate direction rather than summing two representations.
    c = .{type = 3, sourceid = 10, number = 20, scroll_type = 1, increment = 3, flags = 2};
    xi_scroll_class(*axes, *c);
    assert(axes.count == 2 && axes[0].number == 20 && !axes[0].valid);
    assert(!xi_scroll_emulated(axes, 10, 4, 1 << 16)); // new baseline cannot eat the first notch
    assert(!xi_scroll_emulated(axes, 10, 6, 1 << 16)); // this direction also has no delta since reset
    assert(!xi_scroll_emulated(axes, 10, 4, 0));
    assert(!xi_scroll_emulated(axes, 99, 4, 1 << 16));
    assert(!xi_scroll_emulated(axes, 10, 1, 1 << 16)); // emulated touchscreen clicks still work
    array_reset(*axes); // removed device; an ID reused with a new increment starts fresh
    c.number, c.increment = 3, 17;
    xi_scroll_class(*axes, *c);
    d = xi_scroll_delta(axes, 10, v);
    near(d.y, 0);
    values[1] += 0.5;
    d = xi_scroll_delta(axes, 10, v);
    near(d.y, -53.0 / 34);

    // Actual cookie dispatcher: one smooth scroll, no compatibility-wheel duplicate, legacy fallback,
    // normal/emulated clicks, fractional coordinates, modifiers, and re-entry baseline invalidation.
    xs.win = 42;
    s.time_override = 1;
    s.scale = 2;
    array_add(*xi.axes, ..axes);
    defer array_free(xi.axes);
    defer array_free(s.pending);
    e := XIDeviceEvent.{sourceid = 10, event = 42, event_x = 20.5, event_y = 40.25, valuators = v};
    e.mods.effective = 1;
    cookie := XGenericEventCookie.{evtype = 6, data = *e};
    xi_event(*cookie);
    values[1] += 0.25;
    xi_event(*cookie);
    assert(s.pending.count == 3 && s.pending[2].kind == .Scroll && s.pending[2].precise);
    near(s.pending[2].delta.y, -53.0 / 68);
    near(s.pending[2].pos.x, 10.25);
    assert(s.pending[2].mods == .Shift);
    e.detail, e.flags, cookie.evtype = 5, 1 << 16, 4;
    xi_event(*cookie);
    assert(s.pending.count == 3);
    e.flags = 0;
    xi_event(*cookie);
    assert(s.pending.count == 4 && !s.pending[3].precise);
    near(s.pending[3].delta.y, -53);
    e.sourceid, e.flags = 99, 1 << 16;
    xi_event(*cookie); // unsupported source retains emulated wheel fallback
    assert(s.pending.count == 5 && s.pending[4].kind == .Scroll);
    e.detail = 1;
    xi_event(*cookie);
    assert(s.pending.count == 6 && s.pending[5].kind == .Mouse_Down);
    cookie.evtype = 5;
    xi_event(*cookie);
    assert(s.pending.count == 7 && s.pending[6].kind == .Mouse_Up);
    enter := XIEnterEvent.{event = 42};
    cookie.evtype, cookie.data = 7, *enter;
    xi_event(*cookie);
    assert(!xi.axes[0].valid && !xi.axes[0].emitted);
    // First discrete notch after re-entry is not lost to baseline initialization.
    array_reset_keeping_memory(*s.pending);
    cookie.data, cookie.evtype = *e, 6;
    e.sourceid, e.detail, e.flags = 10, 5, 1 << 16;
    xi_event(*cookie);
    cookie.evtype = 4;
    xi_event(*cookie);
    assert(scroll_count(false) == 1 && scroll_count(true) == 0);
    values[1] += 17;
    cookie.evtype = 6;
    xi_event(*cookie);
    cookie.evtype = 4;
    xi_event(*cookie);
    assert(scroll_count(false) == 1 && scroll_count(true) == 1);
    // Reverse button/Motion order: cumulative valuators still emit each notch exactly once.
    array_reset_keeping_memory(*s.pending);
    xi_scroll_reset(xi.axes);
    xi_event(*cookie); // first button seeds baseline and retains its compatibility notch
    cookie.evtype = 6;
    xi_event(*cookie);
    values[1] += 17;
    cookie.evtype = 4;
    xi_event(*cookie); // button supplies the new smooth value before Motion
    cookie.evtype = 6;
    xi_event(*cookie);
    assert(scroll_count(false) == 1 && scroll_count(true) == 1);
    // Buttons unrelated to scrolling keep the same decoding and release path.
    cookie.evtype = 4;
    for detail: s32.[2, 8, 9] {
        e.detail = detail;
        xi_event(*cookie);
        assert(peek(s.pending).button == (ifx detail == 2 then Mouse_Button.Middle else ifx detail == 8 then .X1 else .X2));
        assert(peek(s.pending).kind == .Mouse_Down);
    }
    enter.mode = 1; // NotifyGrab
    cookie.data, cookie.evtype = *enter, 8;
    n := s.pending.count;
    xi_event(*cookie);
    assert(s.pending.count == n); // implicit grab must not cancel a drag
    held := u8.[2];
    enter.mode, enter.buttons = 0, .{mask_len = 1, mask = held.data};
    xi_event(*cookie);
    assert(s.pending.count == n);
    held[0] = 0;
    xi_event(*cookie);
    assert(s.pending.count == n + 1 && peek(s.pending).kind == .Mouse_Leave);

    d = wl_scroll_delta(.[1.25, -2.5], .[0, 0], false);
    near(d.x, 2.5); near(d.y, -1.25);
    d = wl_scroll_delta(.[999, 999], .[30, -60], true);
    near(d.x, 26.5); near(d.y, -13.25);
    d = wl_scroll_delta(.[0, 0], .[0, 0], false);
    near(d.x, 0); near(d.y, 0); // stop-only/empty frame emits no movement

    ui_tests();
    args := get_command_line_arguments();
    if args.count > 1 && args[1] == "--display" display_test();
    print("linux_scroll: XI2 fractional/sparse/baseline/source/emulation, Wayland axes, UI precision passed\n");
}

ui_tests :: () {
    // Platform -> UI precision survives mapping, including fractional deltas.
    ev := p.Event.{kind = .Scroll, delta = .{0.125, -0.25}, precise = true};
    mapped := a.map_events(.[ev]);
    assert(mapped.count == 1 && mapped[0].precise);
    near(mapped[0].delta.y, -0.25);
    state: ui.State;
    ui.init(*state, .{});
    defer ui.shutdown(*state);
    state.mouse = .{20, 20};
    array_add(*state.events, mapped[0]);
    b := ui.Box.{key = 2, flags = .Scroll_X | .Scroll_Y, rect = .{0, 0, 100, 100},
        view_off = .{10, 10}, view_off_target = .{80, 80}};
    ui.signal(*b);
    near(b.view_off.x, 9.875); near(b.view_off.y, 10.25);
    assert(b.view_off == b.view_off_target && state.events[0].consumed);
    other := ui.Box.{key = 3, flags = .Scroll_Y, rect = b.rect, view_off = .{0, 2}, view_off_target = .{0, 50}};
    ui.signal(*other);
    near(other.view_off.y, 2); near(other.view_off_target.y, 50);
    state.events[0] = .{kind = .Scroll, delta = .{0, -53}};
    ui.signal(*b);
    near(b.view_off.y, 10.25); near(b.view_off_target.y, 63.25); // wheel remains animated
    state.dt = 1.0 / 60;
    ui.animate(*b.view_off.y, b.view_off_target.y, 40);
    assert(b.view_off.y > 10.25 && b.view_off.y < 63.25);
    // Shared virtualized picker scrolling uses the same direct-input policy and clamping.
    context.ui = *a.app.ui;
    a.app.ui.mouse, a.app.ui.dt = .{20, 20}, 1.0 / 60;
    array_add(*a.app.ui.events, .{kind = .Scroll, delta = .{0, -0.125}, precise = true});
    defer array_free(a.app.ui.events);
    pk := a.Pk_Scroll.{y = 10, target = 80};
    a.pk_scroll_update(*pk, .{0, 0, 100, 100}, 500);
    near(pk.y, 10.125); near(pk.target, 10.125);
    a.app.ui.events[0] = .{kind = .Scroll, delta = .{0, -53}};
    a.pk_scroll_update(*pk, .{0, 0, 100, 100}, 500);
    assert(pk.y > 10.125 && pk.y < pk.target);
    a.app.ui.events[0] = .{kind = .Scroll, delta = .{0, -9999}, precise = true};
    a.pk_scroll_update(*pk, .{0, 0, 100, 100}, 500);
    near(pk.y, 400); near(pk.target, 400);
    context.ui = *state;
}

// Optional metadata-only native check: one unmapped window, no app session, no event pumping/capture.
display_test :: () {
    xs.lib = dlopen("libX11.so.6", RTLD_NOW);
    assert(xs.lib && load_syms(xs.lib, *X, "X"));
    X.InitThreads();
    xs.d = X.OpenDisplay(null);
    assert(xs.d != null, "--display requires a working X11 display");
    defer X.CloseDisplay(xs.d);
    xs.root = X.DefaultRootWindow(xs.d);
    xs.win = X.CreateSimpleWindow(xs.d, xs.root, 0, 0, 1, 1, 0, 0, 0);
    assert(xs.win != 0);
    defer X.DestroyWindow(xs.d, xs.win);
    xi_init();
    assert(xi.on, "XI2.1 pointer initialization failed");
    GetSelectedEvents := cast((d: *void, w: Window, n: *s32) -> *XIEventMask #c_call) dlsym(xi.lib, "XIGetSelectedEvents");
    assert(GetSelectedEvents != null);
    n: s32;
    masks := GetSelectedEvents(xs.d, xs.win, *n);
    assert(masks && n == 1 && masks[0].deviceid == 1);
    for bit: 4..8 assert(masks[0].mask_len > (bit >> 3) && (masks[0].mask[bit >> 3] & cast(u8) (1 << (bit & 7))) != 0);
    X.Free(masks);
    masks = GetSelectedEvents(xs.d, xs.root, *n);
    assert(masks && n == 1 && masks[0].deviceid == 0 && (masks[0].mask[0] & 2) != 0 && (masks[0].mask[1] & 8) != 0);
    X.Free(masks);
    print("XI2.1 native init: master pointer Motion/Buttons/Enter/Leave + root device notifications selected; % scroll axes\n", xi.axes.count);
    for xi.axes print("  source % axis % horizontal % increment %\n", it.source, it.number, it.horizontal, it.increment);
    xi.on = false;
    array_reset(*xi.axes);
}
