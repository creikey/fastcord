# nghttp3

HTTP/3 and QPACK (RFC 9114/9204) for `src/quic`, on top of ngtcp2. Upstream's release files,
unmodified: `lib/` (sources, private headers, public `includes/nghttp3/nghttp3.h` and the release's
generated `version.h`), `lib/sfparse/` (its structured-field parser, with its own `COPYING`), plus
`COPYING`. No tests or examples.

- Source: https://github.com/ngtcp2/nghttp3, release v1.18.0, `nghttp3-1.18.0.tar.gz`
- sha256 of the tarball: 2812e9c06583fa24c8dc46bdb5291310a69196352ceaca8fbe98106ff36ae7d8
- Licence: MIT (COPYING).

Why: ngtcp2's companion HTTP/3 library (same author), used by curl, fuzzed by OSS-Fuzz. It replaced a
hand-written HTTP/3 client and QPACK decoder.

`fc_nghttp3.sources` lists the 32 C files `build.jai` compiles into `build/fc_vendor.a`;
`fc_nghttp3.cflags` holds the include paths and `NGHTTP3_STATICLIB`.

To update: download the new release tarball, copy the same files, regenerate `fc_nghttp3.sources`
(`lib/*.c` plus `lib/sfparse/sfparse.c`, sorted), record the version and sha256 here, then run
`jai build.jai - test`.
