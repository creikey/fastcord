// Threads in the shape the code base uses: create/start/join/destroy, and start-with-data helpers.
#import "Basic";
#import "fc";
J :: #import "Thread";

Thread :: struct {
    jt: J.Thread;
    procedure: (*Thread);
    data: *void;
    user_index: int;
    run: (*Thread);  // trampoline for the *_with_*data variants
    ctx: type_of(context);
}

entry :: (jt: *J.Thread) -> s64 {
    t := cast(*Thread) jt.data;
    if t.run t.run(t);
    else if t.procedure t.procedure(t);
    return 0;
}

create :: (p: (*Thread)) -> *Thread {
    t := New(Thread);
    t.procedure = p;
    t.ctx = context;
    return t;
}
start :: (t: *Thread) {
    J.thread_init(*t.jt, entry);
    t.jt.data = t;
    t.jt.starting_context = t.ctx;
    t.jt.starting_context.temporary_storage = *t.jt.starting_temporary_storage;  // each thread its own temp memory
    J.thread_start(*t.jt);
}
join :: (t: *Thread) { J.thread_is_done(*t.jt, -1); }
destroy :: (t: *Thread) { join(t); J.thread_deinit(*t.jt); free(t); }
is_done :: (t: *Thread) -> bool { return J.thread_is_done(*t.jt, 0); }
yield :: () { sleep_milliseconds(0); }

create_and_start :: (p: (), init_context: *type_of(context) = null, self_cleanup := false) -> *Thread {
    t := create(null);
    if init_context t.ctx = init_context.*;
    t.data = cast(*void) p;
    t.run = (t: *Thread) { (cast(()) t.data)(); };
    start(t);
    return t;
}
create_and_start_with_data :: (data: *void, p: (*void), init_context: *type_of(context) = null, self_cleanup := false) -> *Thread {
    Box :: struct { d: *void; p: (*void); }
    t := create(null);
    if init_context t.ctx = init_context.*;
    b := New(Box); b.d = data; b.p = p;
    t.data = b;
    t.run = (t: *Thread) { b := cast(*Box) t.data; b.p(b.d); };
    start(t);
    return t;
}
create_and_start_with_poly_data :: (data: $D, p: (D), init_context: *type_of(context) = null, self_cleanup := false) -> *Thread {
    Box :: struct { d: D; p: (D); }
    t := create(null);
    if init_context t.ctx = init_context.*;
    b := New(Box); b.d = data; b.p = p;
    t.data = b;
    t.run = (t: *Thread) { b := cast(*Box) t.data; b.p(b.d); };
    start(t);
    return t;
}
run_with_poly_data :: (data: $D, p: (D), init_context: *type_of(context) = null) { create_and_start_with_poly_data(data, p, init_context, true); }
