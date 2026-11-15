// Forced into every whisper.cpp file by fc_whisper.cflags: the defines upstream CMake would pass.
#define WHISPER_VERSION "1.9.5"
#define PARAKEET_VERSION "1.9.5"
#if defined(__linux__) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE // ggml-cpu.c's CPU_ZERO and pthread_setaffinity_np
#endif
