// Futex-based Mutex / Cond that work zero-initialized, plus the atomics the code base uses.
#import "Basic";
#import "fc";
#import "Atomics";
time :: #import "fc_time";

Mutex :: struct { state: u32; }  // 0 free, 1 locked, 2 locked with waiters
Cond :: struct { seq: u32; }
Once :: struct { done: u32; m: Mutex; }

mutex_try_lock :: (m: *Mutex) -> bool { ok := compare_and_swap(*m.state, 0, 1); return ok; }
mutex_lock :: (m: *Mutex) {
    if compare_and_swap(*m.state, 0, 1) return;
    while atomic_exchange(*m.state, 2) != 0 futex_wait(*m.state, 2, -1);
}
mutex_unlock :: (m: *Mutex) {
    if atomic_exchange(*m.state, 0) == 2 futex_wake(*m.state, false);
}
cond_wait :: (c: *Cond, m: *Mutex) { cond_wait_with_timeout(c, m, -1); }
cond_wait_with_timeout :: (c: *Cond, m: *Mutex, d: time.Duration) -> bool {
    seq := atomic_load(*c.seq);
    mutex_unlock(m);
    ok := futex_wait(*c.seq, seq, d);
    mutex_lock(m);
    return ok;
}
cond_signal :: (c: *Cond) { atomic_add(*c.seq, 1); futex_wake(*c.seq, false); }
cond_broadcast :: (c: *Cond) { atomic_add(*c.seq, 1); futex_wake(*c.seq, true); }
once_do :: (o: *Once, p: ()) {
    if atomic_load(*o.done) return;
    mutex_lock(*o.m);
    if !o.done { p(); atomic_store(*o.done, 1); }
    mutex_unlock(*o.m);
}

// Ordering arguments are accepted and ignored: every operation is sequentially consistent.
Atomic_Memory_Order :: enum { Relaxed; Consume; Acquire; Release; Acq_Rel; Seq_Cst; }
atomic_load_explicit :: inline (p: *$T, o: Atomic_Memory_Order) -> T { return atomic_load(p); }
atomic_store_explicit :: inline (p: *$T, v: T, o: Atomic_Memory_Order) { atomic_store(p, v); }
atomic_sub :: inline (p: *$T, v: T) -> T { return atomic_add(p, -v); }
atomic_compare_exchange_strong :: inline (p: *$T, old: T, new: T) -> T, bool { ok, prev := compare_and_swap(p, old, new); return prev, ok; }

#if OS == .MACOS {
    libsystem :: #system_library "libSystem";
    __ulock_wait :: (op: u32, addr: *void, value: u64, timeout_us: u32) -> s32 #foreign libsystem;
    __ulock_wake :: (op: u32, addr: *void, wake_value: u64) -> s32 #foreign libsystem;
    pthread_threadid_np :: (thread: *void, id: *u64) -> s32 #foreign libsystem;
    UL_COMPARE_AND_WAIT :: 1;
    ULF_WAKE_ALL :: 0x100;
    ULF_NO_ERRNO :: 0x1000000;
    futex_wait :: (addr: *u32, expected: u32, d: time.Duration) -> bool {
        us: u32 = ifx d < 0 then 0 else cast(u32) clamp(d / 1000, 1, 0xFFFF_FFFF);
        r := __ulock_wait(UL_COMPARE_AND_WAIT | ULF_NO_ERRNO, addr, expected, us);
        return r != -60;  // ETIMEDOUT
    }
    futex_wake :: (addr: *u32, all: bool) {
        while true {
            r := __ulock_wake(UL_COMPARE_AND_WAIT | ULF_NO_ERRNO | (cast(u32) (ifx all then ULF_WAKE_ALL else 0)), addr, 0);
            if r != -4 break;  // EINTR
        }
    }
    current_thread_id :: () -> int { id: u64; pthread_threadid_np(null, *id); return cast(int) id; }
} else #if OS == .WINDOWS {
    synch :: #system_library "api-ms-win-core-synch-l1-2-0";
    kernel32 :: #system_library "kernel32";
    WaitOnAddress :: (addr: *void, compare: *void, size: u64, ms: u32) -> s32 #foreign synch;
    WakeByAddressSingle :: (addr: *void) #foreign synch;
    WakeByAddressAll :: (addr: *void) #foreign synch;
    GetCurrentThreadId :: () -> u32 #foreign kernel32;
    futex_wait :: (addr: *u32, expected: u32, d: time.Duration) -> bool {
        e := expected;
        ms: u32 = ifx d < 0 then 0xFFFF_FFFF else cast(u32) clamp(d / 1_000_000, 0, 0xFFFF_FFFE);
        return WaitOnAddress(addr, *e, 4, ms) != 0;
    }
    futex_wake :: (addr: *u32, all: bool) { if all WakeByAddressAll(addr); else WakeByAddressSingle(addr); }
    current_thread_id :: () -> int { return cast(int) GetCurrentThreadId(); }
}
