// WebRTC's macOS code includes this private header, which zig's macOS headers lack. It only needs the
// mutex policy name; the policy itself is public in <pthread.h>.
#include <pthread.h>
#define _PTHREAD_MUTEX_POLICY_FIRSTFIT PTHREAD_MUTEX_POLICY_FIRSTFIT_NP
