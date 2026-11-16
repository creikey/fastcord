# nghttp3

HTTP/3 and QPACK (RFC 9114/9204) for `src/quic`, on top of ngtcp2. Upstream's release files,
unmodified: `lib/` (sources, private headers, public `includes/nghttp3/nghttp3.h` and the release's
generated `version.h`), `lib/sfparse/` (its structured-field parser, with its own `COPYING`), plus
`COPYING`. No tests or examples.

- Upstream: https://github.com/ngtcp2/nghttp3 v1.18.0
- Source: https://github.com/ngtcp2/nghttp3, release v1.18.0, `nghttp3-1.18.0.tar.gz`
- sha256 of the tarball: 2812e9c06583fa24c8dc46bdb5291310a69196352ceaca8fbe98106ff36ae7d8
- Licence: MIT (COPYING).

Why: ngtcp2's companion HTTP/3 library (same author), used by curl, fuzzed by OSS-Fuzz. It replaced a
hand-written HTTP/3 client and QPACK decoder.

`fc_nghttp3.sources` lists the 32 C files `build.jai` compiles into `build/fc_vendor.a`;
`fc_nghttp3.cflags` holds the include paths and `NGHTTP3_STATICLIB`.

## Patches

`patches/` holds our changes to the upstream files; `build.jai` applies them to a copy in `build/patched/nghttp3`
(AGENTS.md). They make the control and QPACK streams carry what Chrome 148 (QUICHE) sends;
`quic_h3_control_stream` checks them.

- `0001-chrome-control-stream.patch`:
  - SETTINGS sorted by identifier (01, 06, 07, 33, as QUICHE's `SerializeSettingsFrame`), then a GREASE setting
    (0x1f * N + 0x21 = a random 32-bit value) and, after the frame, a GREASE frame of N % 4 random bytes
    (`QuicSendControlStream::MaybeSendSettingsFrame`, `HttpEncoder::SerializeGreasingFrame`); a client draws
    them from the `rand` callback.
  - The QPACK encoder and decoder streams send their stream type only with their first instruction
    (`QpackSendStream::MaybeSendStreamType`), so unused ones stay silent.
  - A request's PRIORITY_UPDATE waits in the request's own queue and goes to the control stream just before
    its HEADERS (QUICHE writes it from `SetPriority`, right before `WriteHeaders`), instead of every queued
    PRIORITY_UPDATE going ahead of every request.

To update: download the new release tarball, copy the same files, regenerate `fc_nghttp3.sources`
(`lib/*.c` plus `lib/sfparse/sfparse.c`, sorted), record the version and sha256 here, re-make the patch against
the new files (`diff -ru nghttp3.orig nghttp3`), then run `jai build.jai - test quic_`.
