#import "Basic";
R :: #import "Random";
float64_ :: () -> float64 { return cast(float64) R.random_get_zero_to_one_open(); }
uint32_ :: () -> u32 { return cast(u32) R.random_get(); }
int_max :: (n: int) -> int { return cast(int) (R.random_get() % cast(u64) n); }
int31_max :: (n: s32) -> s32 { return cast(s32) (R.random_get() % cast(u64) n); }
