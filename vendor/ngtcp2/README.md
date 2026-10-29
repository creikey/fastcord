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

`fc_ngtcp2.sources` lists the 48 C files `build.jai` compiles into `build/fc_vendor.a`;
`fc_ngtcp2.cflags` holds the include paths and `NGTCP2_STATICLIB`. No `config.h`: the code's fallbacks cover Windows and macOS.

`fc_ngtcp2.c` is ours, not upstream: the glue `src/quic` calls, bridging ngtcp2 and nghttp3. Its
`client_initial` uses `ngtcp2_crypto_derive_and_install_initial_key`, which is exported but declared only
in `crypto/shared.h`, so that we can set Chrome's exact transport parameter bytes (`fc_quic_chrome_tp`, with
Chrome 152's `google_connection_options` "ORIG" unless the host runs an older Chrome); recheck it on update.

Its `fc_quic_new` takes the server's 0-RTT transport parameters from the last connection
(`fc_quic_0rtt_tp`): with them a resumed session starts HTTP/3 in 0-RTT, and if the server refuses early data
the requests go again on 1-RTT. `fc_h3_preview` is for `quic_h3_control_stream` only.

## Patches

`patches/` holds our changes to the upstream files; `build.jai` applies them to a copy in `build/patched/ngtcp2`
(AGENTS.md). They make ngtcp2 send what Chrome 148 and 152 (QUICHE) send; `quic_chrome_initials` checks them.

- `0001-chrome-initial-packets.patch`:
  - `conn_crumble_initial_crypto` replaced by QUICHE's layout of Initial CRYPTO data
    (`QuicPacketCreator::MultiPacketChaosProtect`, `QuicChaosProtector`): a ClientHello that needs several
    packets puts its first 55-86 bytes and its tail in packet 1 and its middle in the next; in each packet the
    CRYPTO frames are split 2-10 more times, 2-10 PINGs added, the padding spread between the frames, and all
    of them shuffled.
  - `pktns_select_pkt_numlen`: packet numbers take at least 2 bytes, except the Initial packet numbered 1.
  - `NGTCP2_PKT_LENGTHLEN` 2: the long header's Length field is a 2-byte varint, not 4.
- `0002-chrome-packet-numbers.patch`: packets are numbered from one counter shared by the Initial, Handshake
  and 1-RTT spaces (`conn_next_pkt_num`), as QUICHE's `QuicPacketCreator::NextSendingPacketNumber` does, and
  no 1-RTT packet number is skipped (ngtcp2 skips some at random against optimistic ACKs; Chrome doesn't).
  A space's numbers then have gaps where other spaces sent, so near the handshake's end loss detection's
  packet threshold can count a packet lost early, costing at most a spurious retransmission.

To update: download the new release tarball, copy the same files, regenerate `fc_ngtcp2.sources`
(`lib/*.c` plus the two crypto files, sorted), record the version and sha256 here, re-make each patch against the
new files (`diff -ru ngtcp2.orig ngtcp2`), then run `jai build.jai - test quic_`.
