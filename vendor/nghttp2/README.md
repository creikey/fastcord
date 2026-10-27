# nghttp2

HTTP/2 client: framing, HPACK, flow control, stream states and validation of everything the server
sends (`src/http/h2.jai` binds it). Upstream's `lib/` sources and headers, unmodified (build files
dropped), plus `COPYING`.

- Source: https://github.com/nghttp2/nghttp2/releases/tag/v1.70.0, `nghttp2-1.70.0.tar.gz`
- sha256 of the tarball: aa317e2cf9dca6afa0aed68f8fad6ff303ec6982e25a78c75c0b65e2b9b3ded5
  (matches the release's `checksums.txt`)
- Licence: MIT (COPYING).

Why: it is the HTTP/2 library behind curl, Apache httpd and Node.js, fuzzed continuously by OSS-Fuzz.
It replaced a hand-written framer and HPACK coder. 1.68.1 or later is required (CVE-2026-27135).

Fingerprint cost: since 1.65 nghttp2 ignores RFC 7540 priority, so request HEADERS lack the PRIORITY
flag and weight Chrome sends, and its HPACK encoder makes its own indexing choices. SETTINGS (values
and order), the connection WINDOW_UPDATE and the pseudo-header order still match Chrome.

`fc_nghttp2.c` and `fc_nghttp2_http.c` are ours: unity builds with the defines upstream's CMake would
generate. `nghttp2_http.c` gets its own unit because it and `nghttp2_helper.c` both define a static
`VALID_AUTHORITY_CHARS`.

To update: replace `lib/` with the new release's `lib/*.c`, `lib/*.h` and `lib/includes/nghttp2/*.h`,
check whether a new `.c` file needs adding to `fc_nghttp2.c`, record the version and sha256 here,
then run `odin test src/http -collection:fc=src`.
