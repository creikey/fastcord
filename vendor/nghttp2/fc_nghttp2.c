// fastcord's translation units for nghttp2: upstream's lib/, configured the way its CMake build
// configures a static library. nghttp2_http.c and nghttp2_helper.c both define a static
// VALID_AUTHORITY_CHARS, so nghttp2_http.c is its own unit (fc_nghttp2_http.c includes this file with
// FC_NGHTTP2_HTTP set). Bound in src/http/h2.jai. Built by build.jai into
// build/fc_vendor.a.

#define NGHTTP2_STATICLIB
#define BUILDING_NGHTTP2
#ifdef _WIN32
#include <stdint.h>
typedef intptr_t ssize_t;
#define HAVE_WINDOWS_H 1
#define HAVE_GETTICKCOUNT64 1
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#else
#define HAVE_ARPA_INET_H 1
#define HAVE_NETINET_IN_H 1
#define HAVE_CLOCK_GETTIME 1
#define HAVE_DECL_CLOCK_MONOTONIC 1
#endif

#ifdef FC_NGHTTP2_HTTP
#include "lib/nghttp2_http.c"
#else
#include "lib/nghttp2_alpn.c"
#include "lib/nghttp2_buf.c"
#include "lib/nghttp2_callbacks.c"
#include "lib/nghttp2_debug.c"
#include "lib/nghttp2_extpri.c"
#include "lib/nghttp2_frame.c"
#include "lib/nghttp2_hd.c"
#include "lib/nghttp2_hd_huffman.c"
#include "lib/nghttp2_hd_huffman_data.c"
#include "lib/nghttp2_helper.c"
#include "lib/nghttp2_map.c"
#include "lib/nghttp2_mem.c"
#include "lib/nghttp2_option.c"
#include "lib/nghttp2_outbound_item.c"
#include "lib/nghttp2_pq.c"
#include "lib/nghttp2_priority_spec.c"
#include "lib/nghttp2_queue.c"
#include "lib/nghttp2_ratelim.c"
#include "lib/nghttp2_rcbuf.c"
#include "lib/nghttp2_session.c"
#include "lib/nghttp2_stream.c"
#include "lib/nghttp2_submit.c"
#include "lib/nghttp2_time.c"
#include "lib/nghttp2_version.c"
#include "lib/sfparse.c"
#endif
