# ngtcp2

QUIC (RFC 9000/9001/9002) for `src/quic`, with its BoringSSL crypto backend driving the vendored
BoringSSL. Upstream's release files, unmodified: `lib/` (sources, private headers, public
`includes/ngtcp2/ngtcp2.h` and the release's generated `version.h`), `crypto/shared.c`, `crypto/shared.h`,
`crypto/boringssl/boringssl.c`, `crypto/includes/ngtcp2/ngtcp2_crypto.h` and
`ngtcp2_crypto_boringssl.h`, plus `COPYING`. No tests, examples, qlog writer use or other TLS backends.

- Source: https://github.com/ngtcp2/ngtcp2, release v1.25.0, `ngtcp2-1.25.0.tar.gz`
- sha256 of the tarball: 1c0843076528a87b65e9a9d455100941f4cb65d44f96c5da6ae56df146043955
- Licence: MIT (COPYING).

Why: it is the QUIC stack curl and others ship, written by the nghttp2 author, fuzzed by OSS-Fuzz, and
its BoringSSL backend lets the handshake use the same TLS library and Chrome-shaped settings as
`src/tls`. It replaced a hand-written QUIC client.

`fc_ngtcp2.sources` lists the 48 C files `build.sh` / `build.bat` compile into `build/fc_ngtcp2.lib`
(Windows, with clang-cl when present) or `build/libfc_ngtcp2.a` (macOS); `fc_ngtcp2.cflags` holds the
include paths and `NGTCP2_STATICLIB`. No `config.h`: the code's fallbacks cover Windows and macOS.

To update: download the new release tarball, copy the same files, regenerate `fc_ngtcp2.sources`
(`lib/*.c` plus the two crypto files, sorted), record the version and sha256 here, then run
`./build.sh test quic`.
