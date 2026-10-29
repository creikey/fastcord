# BoringSSL

TLS for every TCP connection (`src/tls`), and the TLS 1.3 stack ngtcp2 will drive for QUIC. Upstream's
libcrypto and libssl sources, unmodified (our one change is a patch, below): the `bcm`, `crypto` and `ssl` targets' `srcs`, `hdrs`,
`internal_hdrs`, `asm` and `nasm` from `gen/sources.json`, plus `LICENSE`. No tests, tools, `pki/`,
`decrepit/` or Rust.

- Upstream: https://github.com/google/boringssl 572a4c68475d284b34675f45ddbb9c158ef3c2ae
- Source: https://github.com/google/boringssl, commit 572a4c68475d284b34675f45ddbb9c158ef3c2ae
  (2026-07-27, the `boringssl_revision` in Chromium 152.0.7977.167's DEPS), `archive/<commit>.tar.gz`
- sha256 of the tarball: d032402a5b2304dda097aba638101ea53b4014f8f176dcf26033d0354083c06a
- Licence: Apache-2.0 (LICENSE).

Why: it is Chrome's TLS library, so Chrome's ClientHello comes from the same code, and it is fuzzed
continuously by OSS-Fuzz. It replaced a hand-written TLS 1.3 client. Chrome's revision, not another: the
hello changes between revisions. This one is Chrome 152's (the official client's Electron 44), and with
`src/tls`'s settings for an older host it still sends Chrome 148's hello byte for byte: 152 differs only in
the signature algorithms Chromium configures (ML-DSA, and `SSL_CTX_set_grease_sigalgs_enabled`).

`fc_boringssl.sources` lists the 437 files `build.jai` compiles (in parallel) into
`build/fc_vendor.a` (arm64 + x86_64); `fc_boringssl.cflags` holds the defines. It is C++17, built
without exceptions or RTTI; `src/tls` links the system libc++.

The assembly is built as Chrome builds it, so `EVP_has_aes_hardware()` sees AES hardware and picks the
TLS 1.3 cipher order and the ECH GREASE AEAD (AES-128-GCM) as Chrome does. Every `.S` file guards
itself by OS and CPU and assembles to nothing elsewhere, so all are compiled for every target. The
Windows `.asm` files are NASM's: `build.jai` downloads a pinned NASM on Windows and skips them on other
hosts.

## Patches

`patches/` holds our changes to the upstream files; `build.jai` applies them to a copy in
`build/patched/boringssl` (AGENTS.md). Chrome's hello is unchanged by them (`tls_chrome_hello`).

- `0001-rustls-hello.patch`: `SSL_CTX_fc_set_rustls_hello`, for `src/tls`'s rustls 0.23 profile (the
  official Linux updater's ClientHello; `ostls_client_hello` checks it against a capture). On such a
  context a client with TLS 1.2 enabled sends `TLS_EMPTY_RENEGOTIATION_INFO_SCSV` last among its cipher
  suites instead of the renegotiation_info extension (still accepting the server's), never adds the
  padding extension, and orders its extensions as rustls does: sorted by rustls's
  `low_quality_integer_hash` of a random 16-bit seed and each extension's type, not uniformly permuted.
  BoringSSL has no setting for any of the three. The TLS 1.3 suite order rustls uses is the CNSA
  compliance policy's, so that needs no patch.

To update: download the new commit's tarball, copy the same subset (every file those three targets
list in `gen/sources.json`), regenerate `fc_boringssl.sources` from their `srcs`, `asm` and `nasm`
(paths prefixed with `vendor/boringssl/`, sorted), record the commit and sha256 here, re-make the patch
against the new files (`diff -ru boringssl.orig boringssl`), then check the ClientHello against a Chrome
capture and run `jai build.jai - test ostls_client_hello`.
