#import "Basic";
#import "String";
#import "Hash_Table";
#import "Flat_Pool";
#import "Math";
etf :: #import "etf";
vector :: #import "vector";
#load "load.jai";
#load "render.jai";

#scope_module

// Odin's [2]f32 / [4]f32 are Math's Vector2 / Vector4. Math's `v / k` multiplies by 1/k, which changes
// pixels; this module's own operator divides per component like Odin (module scope wins over Math's).
operator / :: (a: Vector2, k: float32) -> Vector2 { return .{a.x / k, a.y / k}; }
operator *[] :: (v: *Vector4, i: int) -> *float32 { return *v.component[i]; }

// Odin's math.mod is C fmod (Math's fmod_cycling rounds differently).
// glibc keeps the math functions in libm, which a native Linux build checks at compile time.
#if OS == .WINDOWS libc :: #system_library "msvcrt";
else #if OS == .LINUX libc :: #system_library "libm";
else libc :: #system_library "libc";
fmod :: (x: float64, y: float64) -> float64 #foreign libc;
