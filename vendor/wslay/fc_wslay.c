// fastcord's one translation unit for wslay: upstream's lib/. Bound in src/http/ws.jai. Built by
// build.jai into build/fc_vendor.a.

#define WSLAY_VERSION "1.1.1-0e7d106"
#ifdef _WIN32
#include <stdint.h>
typedef intptr_t ssize_t;
#define HAVE_WINSOCK2_H 1
#define WIN32_LEAN_AND_MEAN
#else
#define HAVE_ARPA_INET_H 1
#define HAVE_NETINET_IN_H 1
#endif

#include "lib/wslay_event.c"
#include "lib/wslay_frame.c"
#include "lib/wslay_net.c"
#include "lib/wslay_queue.c"
