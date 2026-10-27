# wslay

WebSocket framing (RFC 6455): masking, fragmentation, control frames, the close handshake, UTF-8
and close-code validation (`src/http/ws.odin` binds it; the HTTP upgrade is ours). Upstream's `lib/`
sources and headers, unmodified (build files dropped), plus `COPYING`.

- Source: https://github.com/tatsuhiro-t/wslay at commit 0e7d106ff89ad6638090fd811a9b2e4c5dda8d40
  (2022-08-25: release 1.1.1 plus upstream's UBSan fixes), GitHub's tarball of that commit
- sha256 of the tarball: ce62e7108b2f281c630ce3b12470703f208bc5c97bc3a5ba61e7591838c52448
- Licence: MIT (COPYING).

Why: it is the framing library by nghttp2's author, small (about 2.8k lines) and used by aria2. It replaced a hand-written framer.

`fc_wslay.c` is ours: a unity build of the four `.c` files. It defines `WSLAY_VERSION` itself
because upstream generates `wslayver.h` at configure time.

To update: replace `lib/` with the new commit's `lib/*.c`, `lib/*.h` and `lib/includes/wslay/wslay.h`,
record the commit and sha256 here and in `WSLAY_VERSION`, then run `odin test src/http -collection:fc=src`.
