// One app per <state>. The first launch claims it and gets each later launch's message as an Open_Url event
// (text: a URL from that launch's command line, or "" to show the window). A later launch hands its message
// over and gets false: it should exit. key names the <state>, so a test account's state runs beside the
// real one. macOS also delivers URLs opened from other apps as Open_Url (application:openURLs:).
instance_claim :: (key: string, message: string) -> bool {
    if message.count > INSTANCE_MESSAGE_MAX return true;
    h: u64 = 0xcbf29ce484222325; // FNV-1a: a short, stable name for the key
    for 0..key.count - 1 h = (h ^ key[it]) * 0x100000001b3;
    return os_instance_claim(tprint("fastcord-%", formatInt(h, base = 16)), message);
}

INSTANCE_MESSAGE_MAX :: 4096;

#scope_file

#if OS != .WINDOWS {

// A lock file says who is first (flock ends with the process, so a crash leaves nothing stale); a Unix
// socket beside it carries the message. Both live in a per-user directory.
os_instance_claim :: (name: string, message: string) -> bool {
    dir := getenv_s(#run ifx OS == .MACOS then "TMPDIR" else "XDG_RUNTIME_DIR");
    if dir == "" dir = getenv_s("HOME");
    if dir == "" return true;
    while ends_with(dir, "/") dir.count -= 1;
    lock_path := tprint("%/%.lock", dir, name);
    sock_path := tprint("%/%.sock", dir, name);
    addr: Sockaddr_Un;
    if sock_path.count >= addr.path.count return true;
    memcpy(addr.path.data, sock_path.data, sock_path.count);

    fd := open(temp_c_string(lock_path), O_RDWR | O_CREAT | O_CLOEXEC, cast(s32) 0x180);
    if fd < 0 return true;
    if flock(fd, LOCK_EX | LOCK_NB) == 0 {
        // First: the lock fd stays open for the life of the process.
        unlink(addr.path.data);
        l := socket(AF_UNIX, SOCK_STREAM, 0);
        if l < 0 return true;
        if bind(l, *addr, size_of(Sockaddr_Un)) != 0 || listen(l, 8) != 0 { close(l); return true; }
        inst.listener = l;
        thread_init(*inst.thread, instance_listen);
        thread_start(*inst.thread);
        return true;
    }
    close(fd);
    // Another launch holds it. It may be starting up, so give its socket a moment to appear.
    for 1..20 {
        c := socket(AF_UNIX, SOCK_STREAM, 0);
        if c < 0 return true;
        one: s32 = 1;
        #if OS == .MACOS setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, *one, size_of(s32));
        if connect(c, *addr, size_of(Sockaddr_Un)) == 0 {
            sent := 0;
            while sent < message.count {
                n := send(c, message.data + sent, xx (message.count - sent), MSG_NOSIGNAL);
                if n <= 0 break;
                sent += n;
            }
            close(c);
            return false;
        }
        close(c);
        sleep_milliseconds(100);
    }
    return false; // the holder is alive but not listening: still don't open a second client
}

instance_listen :: (t: *Thread) -> s64 {
    while true {
        c := accept(inst.listener, null, null);
        if c < 0 { sleep_milliseconds(100); continue; }
        tv := Timeval.{1, 0};
        setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, *tv, size_of(Timeval));
        buf: [INSTANCE_MESSAGE_MAX]u8;
        got := 0;
        while got < buf.count {
            n := recv(c, buf.data + got, xx (buf.count - got), 0);
            if n <= 0 break;
            got += n;
        }
        close(c);
        push_event(.{kind = .Open_Url, text = .{got, buf.data}, time = time_now()});
        request_frame();
    }
    return 0;
}

inst: struct {
    listener: s32 = -1;
    thread: Thread;
};

getenv_s :: (name: string) -> string { p := getenv(temp_c_string(name)); return ifx p then to_string(p) else ""; }

libc_i :: #system_library "libc";
getenv :: (name: *u8) -> *u8 #foreign libc_i;
open :: (path: *u8, flags: s32, mode: ..Any) -> s32 #foreign libc_i; // C varargs
close :: (fd: s32) -> s32 #foreign libc_i;
unlink :: (path: *u8) -> s32 #foreign libc_i;
flock :: (fd: s32, op: s32) -> s32 #foreign libc_i;
socket :: (domain: s32, type: s32, protocol: s32) -> s32 #foreign libc_i;
bind :: (fd: s32, addr: *Sockaddr_Un, len: u32) -> s32 #foreign libc_i;
listen :: (fd: s32, backlog: s32) -> s32 #foreign libc_i;
accept :: (fd: s32, addr: *void, len: *u32) -> s32 #foreign libc_i;
connect :: (fd: s32, addr: *Sockaddr_Un, len: u32) -> s32 #foreign libc_i;
send :: (fd: s32, buf: *u8, n: u64, flags: s32) -> s64 #foreign libc_i;
recv :: (fd: s32, buf: *u8, n: u64, flags: s32) -> s64 #foreign libc_i;
setsockopt :: (fd: s32, level: s32, name: s32, value: *void, len: u32) -> s32 #foreign libc_i;

Timeval :: struct { sec: s64; usec: s64; } // macOS reads a 32-bit usec, padded to the same 16 bytes
AF_UNIX :: 1;
SOCK_STREAM :: 1;
LOCK_EX :: 2;
LOCK_NB :: 4;
#if OS == .MACOS {
    Sockaddr_Un :: struct { len: u8 = 106; family: u8 = AF_UNIX; path: [104]u8; }
    O_RDWR :: 0x2; O_CREAT :: 0x200; O_CLOEXEC :: 0x1000000;
    SOL_SOCKET :: 0xffff; SO_RCVTIMEO :: 0x1006; SO_NOSIGPIPE :: 0x1022;
    MSG_NOSIGNAL :: 0;
} else {
    Sockaddr_Un :: struct { family: u16 = AF_UNIX; path: [108]u8; }
    O_RDWR :: 0x2; O_CREAT :: 0x40; O_CLOEXEC :: 0x80000;
    SOL_SOCKET :: 1; SO_RCVTIMEO :: 20;
    MSG_NOSIGNAL :: 0x4000;
}

} // OS != .WINDOWS
