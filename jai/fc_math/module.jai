M :: #import "Math";
PI :: M.PI64;
TAU :: M.TAU64;
sqrt :: inline (x: $T) -> T { return M.sqrt(x); }
sin :: inline (x: $T) -> T { return M.sin(x); }
cos :: inline (x: $T) -> T { return M.cos(x); }
tan :: inline (x: $T) -> T { return M.tan(x); }
acos :: inline (x: $T) -> T { return M.acos(x); }
atan2 :: inline (y: $T, x: T) -> T { return M.atan2(y, x); }
floor :: inline (x: $T) -> T { return M.floor(x); }
ceil :: inline (x: $T) -> T { return M.ceil(x); }
round :: inline (x: $T) -> T { return ifx x < 0 then -M.floor(-x + 0.5) else M.floor(x + 0.5); }
pow :: inline (x: $T, y: T) -> T { return M.pow(x, y); }
log10 :: inline (x: $T) -> T { return M.log(x) / M.log(cast(T) 10); }
mod :: inline (x: $T, y: T) -> T { return M.fmod_cycling(x, y); }
clamp :: inline (x: $T, lo: T, hi: T) -> T { return ifx x < lo then lo else ifx x > hi then hi else x; }
