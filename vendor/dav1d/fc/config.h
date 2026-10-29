/* fastcord's stand-in for the config.h dav1d's meson build generates: plain C (no assembly), 8 bits per
   component only, for every OS and CPU fastcord builds. Anything not defined here is 0. */
#ifndef FC_DAV1D_CONFIG_H
#define FC_DAV1D_CONFIG_H

#define CONFIG_8BPC 1
#define CONFIG_16BPC 0
#define CONFIG_LOG 0
#define HAVE_ASM 0
#define TRIM_DSP_FUNCTIONS 0
#define HAVE_C11_GENERIC 1
#define HAVE_SYS_TYPES_H 1

#ifdef _WIN32
#define _WIN32_WINNT 0x0601
#define UNICODE 1
#define _UNICODE 1
#define _CRT_DECLARE_NONSTDC_NAMES 1
#define HAVE_IO_H 1
#else
#if defined(__linux__) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE /* posix_memalign under -std=c11, as meson's _POSIX_C_SOURCE */
#endif
#define HAVE_UNISTD_H 1
#define HAVE_CLOCK_GETTIME 1
#define HAVE_POSIX_MEMALIGN 1
#ifdef __APPLE__
#define HAVE_PTHREAD_SETNAME_NP 1
#endif
#endif

#endif
