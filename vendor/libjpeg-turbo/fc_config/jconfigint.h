/* libjpeg-turbo build number */
#define BUILD  "fastcord"

/* Compiler's inline keyword */
#undef inline

/* How to hide global symbols, obtain function inlining and thread-local storage. MSVC has no
   symbol visibility, no __builtin_ctzl, and a 4-byte unsigned long. */
#ifdef _MSC_VER
#define HIDDEN
#define INLINE  __forceinline
#define THREAD_LOCAL  __declspec(thread)
#define HAVE_INTRIN_H
#else
#define HIDDEN  __attribute__((visibility("hidden")))
#define INLINE  __inline__ __attribute__((always_inline))
#define THREAD_LOCAL  __thread
#define HAVE_BUILTIN_CTZL
#endif

/* Define to the full name of this package. */
#define PACKAGE_NAME  "libjpeg-turbo"

/* Version number of package */
#define VERSION  "3.2.1"

/* The size of `size_t', as computed by sizeof. */
#define SIZEOF_SIZE_T  8

#if defined(_MSC_VER) && defined(HAVE_INTRIN_H)
#if (SIZEOF_SIZE_T == 8)
#define HAVE_BITSCANFORWARD64
#elif (SIZEOF_SIZE_T == 4)
#define HAVE_BITSCANFORWARD
#endif
#endif

#if defined(__has_attribute)
#if __has_attribute(fallthrough)
#define FALLTHROUGH  __attribute__((fallthrough));
#else
#define FALLTHROUGH
#endif
#else
#define FALLTHROUGH
#endif

/*
 * Define BITS_IN_JSAMPLE as either
 *   8   for 8-bit sample values (the usual setting)
 *   12  for 12-bit sample values
 * Only 8 and 12 are legal data precisions for lossy JPEG according to the
 * JPEG standard, and the IJG code does not support anything else!
 */

#ifndef BITS_IN_JSAMPLE
#define BITS_IN_JSAMPLE  8      /* use 8 or 12 */
#endif

#undef C_ARITH_CODING_SUPPORTED
#undef D_ARITH_CODING_SUPPORTED
#undef WITH_SIMD

#if BITS_IN_JSAMPLE == 8

/* Support arithmetic encoding */
/* #undef C_ARITH_CODING_SUPPORTED */

/* Support arithmetic decoding */
/* #undef D_ARITH_CODING_SUPPORTED */

/* Use accelerated SIMD routines. */
/* #undef WITH_SIMD */

#define SIMD_ARCHITECTURE  NONE

/* #undef WITH_SIMDE */

#endif

/* #undef WITH_PROFILE */
