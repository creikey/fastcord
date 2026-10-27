# BoringSSL

TLS for every TCP connection (`src/tls`), and the TLS 1.3 stack ngtcp2 will drive for QUIC. Upstream's
libcrypto and libssl sources, unmodified: the `bcm`, `crypto` and `ssl` targets' `srcs`, `hdrs` and
`internal_hdrs` from `gen/sources.json`, plus `LICENSE`. No assembly (`OPENSSL_NO_ASM`), tests, tools,
`pki/`, `decrepit/` or Rust.

- Source: https://github.com/google/boringssl, commit ce9c15c34bef75c2a40d4e01bc577235f9e52b4e
  (main, 2026-10-26), `archive/<commit>.tar.gz`
- sha256 of the tarball: e8caefd947eb1dc634c17a0842868a77abb6a2154aa8c3d58f4366f8f07dee67
- Licence: Apache-2.0 (LICENSE).

Why: it is Chrome's TLS library, so Chrome's ClientHello comes from the same code, and it is fuzzed
continuously by OSS-Fuzz. It replaced a hand-written TLS 1.3 client.

`fc_boringssl.sources` lists the 284 files `build.sh` / `build.bat` compile (in parallel) into
`build/fc_boringssl.lib` (Windows) or `build/libfc_boringssl.a` (macOS, arm64 + x86_64);
`fc_boringssl.cflags` holds the defines. It is C++17, built without exceptions or RTTI. On Windows it
needs MSVC 2022's `cl` (clang 11 cannot compile it), which `build.bat` finds with vswhere; it links
against the static CRT (LIBCMT), which also supplies the few C++ runtime symbols (`_purecall`, sized
`operator delete`). On macOS `src/tls` links the system libc++.

Without assembly BoringSSL assumes no AES hardware: `src/tls` sets the TLS 1.3 cipher order itself, but
ECH GREASE still picks ChaCha20-Poly1305 where Chrome picks AES-128-GCM.

To update: download the new commit's tarball, copy the same subset (every file those three targets
list in `gen/sources.json`), regenerate `fc_boringssl.sources` from their `srcs` (paths prefixed with
`vendor/boringssl/`, sorted), record the commit and sha256 here, then run `./build.sh test tls`.
