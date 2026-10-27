M :: #import "Math";
// Untyped, like Odin's constants: float32 maths stays float32.
PI :: 3.14159265358979323846264338327950288;
TAU :: 6.28318530717958647692528676655900576;
sqrt :: inline (x: $T) -> T { return M.sqrt(x); }
sin :: inline (x: $T) -> T { return M.sin(x); }
cos :: inline (x: $T) -> T { return M.cos(x); }
tan :: inline (x: $T) -> T { return M.tan(x); }
acos :: inline (x: $T) -> T { return M.acos(x); }
atan2 :: inline (y: $T, x: T) -> T { return M.atan2(y, x); }
floor :: inline (x: $T) -> T { return M.floor(x); }
ceil :: inline (x: $T) -> T { return M.ceil(x); }
round :: inline (x: $T) -> T { return ifx x < 0 then -M.floor(-x + 0.5) else M.floor(x + 0.5); }
pow :: inline (x: $T, y: $U) -> T { return cast(T) M.pow(cast(float64) x, cast(float64) y); }
log10 :: inline (x: $T) -> T { return M.log(x) / M.log(cast(T) 10); }
// C fmod: the result has the sign of x.
mod :: inline (x: $T, y: T) -> T { return cast(T) fmod(cast(float64) x, cast(float64) y); }
libc :: #system_library "libc";
fmod :: (x: float64, y: float64) -> float64 #foreign libc;
clamp :: inline (x: $T, lo: T, hi: T) -> T { return ifx x < lo then lo else ifx x > hi then hi else x; }
