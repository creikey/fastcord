// fc_ngtcp2.c: the HTTP/3 client connection src/quic drives. It owns every ngtcp2 and nghttp3 object, so
// their struct layouts never cross into Jai; Jai owns the UDP socket, threads, locks and timing, and calls
// these functions with its connection lock held. Events reach Jai through fc_quic_events, synchronously,
// from inside fc_quic_read and fc_quic_handle_expiry; the pointers they pass are valid only during the call.
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN // wincrypt.h's macros clash with BoringSSL's X509_NAME and others.
#include <winsock2.h>
#include <ws2tcpip.h>
#else
#include <netinet/in.h>
#include <sys/socket.h>
#endif
#include <stdlib.h>
#include <string.h>

#include <ngtcp2/ngtcp2.h>
#include <ngtcp2/ngtcp2_crypto.h>
#include <ngtcp2/ngtcp2_crypto_boringssl.h>
#include <nghttp3/nghttp3.h>
#include <openssl/rand.h>
#include <openssl/ssl.h>

#include "shared.h"

typedef struct fc_quic_events {
    void *user;
    void (*header)(void *user, int64_t id, int trailer, const uint8_t *name, size_t nlen, const uint8_t *value, size_t vlen);
    void (*data)(void *user, int64_t id, const uint8_t *p, size_t n);
    // fin=1: the response ended cleanly. fin=0: the stream closed; code is the peer's or our reset code.
    void (*done)(void *user, int64_t id, int fin, uint64_t code);
    void (*goaway)(void *user);
    // The server refused 0-RTT: every open request is gone and must be submitted again once fc_quic_ready.
    void (*rejected)(void *user);
} fc_quic_events;

// A request body, copied at submit and freed when its stream closes or the connection is deleted.
typedef struct fc_body {
    struct fc_body *prev, *next;
    size_t n;
    int sent;
    uint8_t p[];
} fc_body;

typedef struct fc_quic {
    ngtcp2_conn *conn;
    nghttp3_conn *h3;
    SSL *ssl;
    ngtcp2_crypto_conn_ref ref;
    ngtcp2_path_storage ps;
    ngtcp2_ccerr ccerr;
    int failed;
    size_t burst;
    uint64_t rtt_us;
    uint8_t tp[256], ztp[256];
    size_t tplen, ztplen;
    fc_quic_events ev;
    fc_body *bodies;
} fc_quic;

// Chrome 148's client transport parameters (QUICHE): 30 s idle, 15 MiB connection and 6 MiB stream windows,
// 100 bidi and 103 uni streams, 1472-byte UDP payloads, 64 KiB datagram frames.
static void chrome_params(ngtcp2_transport_params *p) {
    ngtcp2_transport_params_default(p);
    p->max_idle_timeout = 30 * NGTCP2_SECONDS;
    p->max_udp_payload_size = 1472;
    p->initial_max_data = 15728640;
    p->initial_max_stream_data_bidi_local = 6291456;
    p->initial_max_stream_data_bidi_remote = 6291456;
    p->initial_max_stream_data_uni = 6291456;
    p->initial_max_streams_bidi = 100;
    p->initial_max_streams_uni = 103;
    p->max_datagram_frame_size = 65536;
}

static uint8_t *put_varint(uint8_t *p, uint64_t v) {
    int n = v < 64 ? 1 : v < 16384 ? 2 : v < 1073741824 ? 4 : 8;
    for (int i = n - 1; i >= 0; i--, v >>= 8) p[i] = (uint8_t)v;
    p[0] |= (uint8_t)((n == 1 ? 0 : n == 2 ? 1 : n == 4 ? 2 : 3) << 6);
    return p + n;
}

// fc_quic_chrome_tp writes into buf (256 bytes) the transport parameters Chrome's ClientHello carries, as
// QUICHE encodes them: chrome_params' values, a zero-length initial_source_connection_id,
// version_information {v1; v1, GREASE}, one GREASE parameter, and Google's initial_rtt (0x3127, in
// microseconds) when rtt_us > 0, in a fresh random order. ngtcp2 keeps its own encoding of the same values
// for its checks; only the bytes the server sees come from here. Returns the length.
size_t fc_quic_chrome_tp(uint8_t *buf, uint64_t rtt_us) {
    ngtcp2_transport_params p;
    chrome_params(&p);
    uint8_t r[64];
    RAND_bytes(r, sizeof r);
    uint8_t vi[12] = {0, 0, 0, 1, 0, 0, 0, 1};
    for (int i = 8; i < 12; i++) vi[i] = (r[24 + i] & 0xf0) | 0x0a;
    uint64_t g = 0;
    for (int i = 40; i < 48; i++) g = g << 8 | r[i];
    struct tp {
        uint64_t id, v;
        const uint8_t *raw;
        size_t rawlen;
    } tmp, tp[13] = {
        {0x03, p.max_udp_payload_size},
        {0x06, p.initial_max_stream_data_bidi_remote},
        {0x07, p.initial_max_stream_data_uni},
        {0x08, p.initial_max_streams_bidi},
        {0x20, p.max_datagram_frame_size},
        {0x0f, 0, r, 0},
        {0x01, p.max_idle_timeout / NGTCP2_MILLISECONDS},
        {0x04, p.initial_max_data},
        {0x05, p.initial_max_stream_data_bidi_local},
        {0x11, 0, vi, sizeof vi},
        {0x09, p.initial_max_streams_uni},
        // Reserved ids are 31 * N + 27 (RFC 9000 18.1), N below (2^62 - 28) / 31 as QUICHE picks it, with
        // up to 15 random bytes.
        {31 * (g % (((1ull << 62) - 28) / 31)) + 27, 0, r + 16, r[3] % 16},
        {0x3127, rtt_us},
    };
    size_t n = rtt_us ? 13 : 12;
    for (size_t i = n - 1; i > 0; i--) {
        size_t j = r[48 + i] % (i + 1);
        tmp = tp[i], tp[i] = tp[j], tp[j] = tmp;
    }
    uint8_t *w = buf;
    for (size_t i = 0; i < n; i++) {
        w = put_varint(w, tp[i].id);
        if (tp[i].raw) {
            w = put_varint(w, tp[i].rawlen);
            memcpy(w, tp[i].raw, tp[i].rawlen);
            w += tp[i].rawlen;
        } else {
            uint8_t v[8];
            size_t vlen = (size_t)(put_varint(v, tp[i].v) - v);
            w = put_varint(w, vlen);
            memcpy(w, v, vlen);
            w += vlen;
        }
    }
    return (size_t)(w - buf);
}

static void set_app_error(fc_quic *q, int liberr) {
    if (!q->failed) ngtcp2_ccerr_set_application_error(&q->ccerr, nghttp3_err_infer_quic_app_error_code(liberr), NULL, 0);
    q->failed = 1;
}

static void rand_cb(uint8_t *dest, size_t n, const ngtcp2_rand_ctx *ctx) {
    (void)ctx;
    RAND_bytes(dest, n);
}

static void h3_rand(uint8_t *dest, size_t n) { RAND_bytes(dest, n); }

static ngtcp2_conn *get_conn(ngtcp2_crypto_conn_ref *ref) { return ((fc_quic *)ref->user_data)->conn; }

static int new_cid(ngtcp2_conn *conn, ngtcp2_cid *cid, ngtcp2_stateless_reset_token *token, size_t cidlen, void *user) {
    (void)conn, (void)user;
    cid->datalen = cidlen;
    return RAND_bytes(cid->data, cidlen) == 1 && RAND_bytes(token->data, sizeof token->data) == 1 ? 0 : NGTCP2_ERR_CALLBACK_FAILURE;
}

// nghttp3 -> Jai and ngtcp2.

static void consume(fc_quic *q, int64_t id, size_t n) {
    ngtcp2_conn_extend_max_stream_offset(q->conn, id, n);
    ngtcp2_conn_extend_max_offset(q->conn, n);
}

static int h3_recv_data(nghttp3_conn *h3, int64_t id, const uint8_t *p, size_t n, void *user, void *sud) {
    fc_quic *q = user;
    (void)h3, (void)sud;
    q->ev.data(q->ev.user, id, p, n);
    consume(q, id, n);
    return 0;
}

static int h3_deferred_consume(nghttp3_conn *h3, int64_t id, size_t n, void *user, void *sud) {
    (void)h3, (void)sud;
    consume(user, id, n);
    return 0;
}

static void header(fc_quic *q, int64_t id, int trailer, nghttp3_rcbuf *name, nghttp3_rcbuf *value) {
    nghttp3_vec n = nghttp3_rcbuf_get_buf(name), v = nghttp3_rcbuf_get_buf(value);
    q->ev.header(q->ev.user, id, trailer, n.base, n.len, v.base, v.len);
}

static int h3_recv_header(nghttp3_conn *h3, int64_t id, int32_t token, nghttp3_rcbuf *name, nghttp3_rcbuf *value, uint8_t flags, void *user, void *sud) {
    (void)h3, (void)token, (void)flags, (void)sud;
    header(user, id, 0, name, value);
    return 0;
}

static int h3_recv_trailer(nghttp3_conn *h3, int64_t id, int32_t token, nghttp3_rcbuf *name, nghttp3_rcbuf *value, uint8_t flags, void *user, void *sud) {
    (void)h3, (void)token, (void)flags, (void)sud;
    header(user, id, 1, name, value);
    return 0;
}

static int h3_end_stream(nghttp3_conn *h3, int64_t id, void *user, void *sud) {
    fc_quic *q = user;
    (void)h3, (void)sud;
    q->ev.done(q->ev.user, id, 1, 0);
    return 0;
}

static int h3_stream_close(nghttp3_conn *h3, int64_t id, uint64_t code, void *user, void *sud) {
    fc_quic *q = user;
    fc_body *b = sud;
    (void)h3;
    if (b) {
        if (b->prev) b->prev->next = b->next; else q->bodies = b->next;
        if (b->next) b->next->prev = b->prev;
        free(b);
    }
    if (ngtcp2_is_bidi_stream(id)) q->ev.done(q->ev.user, id, 0, code);
    return 0;
}

static int h3_stop_sending(nghttp3_conn *h3, int64_t id, uint64_t code, void *user, void *sud) {
    (void)h3, (void)sud;
    return ngtcp2_conn_shutdown_stream_read(((fc_quic *)user)->conn, 0, id, code) ? NGHTTP3_ERR_CALLBACK_FAILURE : 0;
}

static int h3_reset_stream(nghttp3_conn *h3, int64_t id, uint64_t code, void *user, void *sud) {
    (void)h3, (void)sud;
    return ngtcp2_conn_shutdown_stream_write(((fc_quic *)user)->conn, 0, id, code) ? NGHTTP3_ERR_CALLBACK_FAILURE : 0;
}

static int h3_shutdown(nghttp3_conn *h3, int64_t id, void *user) {
    fc_quic *q = user;
    (void)h3, (void)id;
    q->ev.goaway(q->ev.user);
    return 0;
}

static nghttp3_ssize h3_read_body(nghttp3_conn *h3, int64_t id, nghttp3_vec *vec, size_t veccnt, uint32_t *flags, void *user, void *sud) {
    fc_body *b = sud;
    (void)h3, (void)id, (void)veccnt, (void)user;
    *flags |= NGHTTP3_DATA_FLAG_EOF;
    if (b->sent) return 0;
    b->sent = 1;
    vec[0].base = b->p;
    vec[0].len = b->n;
    return 1;
}

// ngtcp2 -> nghttp3, as in ngtcp2's examples/http3_client_proto_codec.cc.

// h3_new makes a client nghttp3_conn on Chrome's streams: control 2 then QPACK decoder 6 and encoder 10, as
// QUICHE opens them (the patched nghttp3 sends a QPACK stream's type only with its first instruction).
static int h3_new(nghttp3_conn **h3, void *user, int64_t ctrl, int64_t dec, int64_t enc) {
    static const nghttp3_callbacks cb = {
        .stream_close = h3_stream_close,
        .recv_data = h3_recv_data,
        .deferred_consume = h3_deferred_consume,
        .recv_header = h3_recv_header,
        .recv_trailer = h3_recv_trailer,
        .stop_sending = h3_stop_sending,
        .end_stream = h3_end_stream,
        .reset_stream = h3_reset_stream,
        .shutdown = h3_shutdown,
        .rand = h3_rand,
    };
    // Chrome's SETTINGS: a 64 KiB QPACK decoder table, 256 KiB header sections, 100 blocked streams,
    // HTTP datagrams, plus (the patched nghttp3) a GREASE setting and GREASE frame. Its encoder never inserts
    // into the dynamic table, and neither does this one.
    nghttp3_settings s;
    nghttp3_settings_default(&s);
    s.max_field_section_size = 262144;
    s.qpack_max_dtable_capacity = 65536;
    s.qpack_encoder_max_dtable_capacity = 0;
    s.qpack_blocked_streams = 100;
    s.h3_datagram = 1;
    if (nghttp3_conn_client_new(h3, &cb, &s, nghttp3_mem_default(), user)) return -1;
    return nghttp3_conn_bind_control_stream(*h3, ctrl) || nghttp3_conn_bind_qpack_streams(*h3, enc, dec) ? -1 : 0;
}

static int setup_h3(fc_quic *q) {
    int64_t ctrl, enc, dec;
    if (ngtcp2_conn_get_streams_uni_left2(q->conn) < 3) return -1;
    if (ngtcp2_conn_open_uni_stream(q->conn, &ctrl, NULL) || ngtcp2_conn_open_uni_stream(q->conn, &dec, NULL) ||
        ngtcp2_conn_open_uni_stream(q->conn, &enc, NULL)) {
        return -1;
    }
    return h3_new(&q->h3, q, ctrl, dec, enc);
}

// client_initial is ngtcp2_crypto_client_initial_cb with Chrome's transport parameter bytes in place of
// ngtcp2's encoding. ngtcp2_crypto_derive_and_install_initial_key is exported but declared only in the
// backend's crypto/shared.h.
// When the hello offers early data and the server's transport parameters from the last connection are known,
// HTTP/3 starts in 0-RTT, as Chrome's does on a resumed session.
static int client_initial(ngtcp2_conn *conn, void *user) {
    fc_quic *q = user;
    q->tplen = fc_quic_chrome_tp(q->tp, q->rtt_us);
    if (ngtcp2_crypto_derive_and_install_initial_key(conn, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, ngtcp2_conn_get_client_chosen_version2(conn), ngtcp2_conn_get_dcid2(conn)) ||
        SSL_set_quic_transport_params(q->ssl, q->tp, q->tplen) != 1 || ngtcp2_crypto_read_write_crypto_data(conn, NGTCP2_ENCRYPTION_LEVEL_INITIAL, NULL, 0)) {
        return NGTCP2_ERR_CALLBACK_FAILURE;
    }
    if (q->ztplen && SSL_in_early_data(q->ssl) && !ngtcp2_conn_decode_and_set_0rtt_transport_params(conn, q->ztp, q->ztplen) && setup_h3(q)) {
        return NGTCP2_ERR_CALLBACK_FAILURE;
    }
    return 0;
}

static int recv_rx_key(ngtcp2_conn *conn, ngtcp2_encryption_level level, void *user) {
    fc_quic *q = user;
    (void)conn;
    if (level != NGTCP2_ENCRYPTION_LEVEL_1RTT || q->h3) return 0;
    return setup_h3(q) ? NGTCP2_ERR_CALLBACK_FAILURE : 0;
}

static void free_bodies(fc_quic *q) {
    for (fc_body *b = q->bodies, *next; b; b = next) {
        next = b->next;
        free(b);
    }
    q->bodies = NULL;
}

// The server refused 0-RTT: ngtcp2 dropped every stream, so HTTP/3 starts again on 1-RTT (recv_rx_key) and
// Jai resubmits its requests, as Chrome resends them.
static int early_data_rejected(ngtcp2_conn *conn, void *user) {
    fc_quic *q = user;
    (void)conn;
    nghttp3_conn_del(q->h3);
    q->h3 = NULL;
    free_bodies(q);
    q->ev.rejected(q->ev.user);
    return 0;
}

static int recv_stream_data(ngtcp2_conn *conn, uint32_t flags, int64_t id, uint64_t offset, const uint8_t *p, size_t n, void *user, void *sud) {
    fc_quic *q = user;
    (void)offset, (void)sud;
    if (!q->h3) return NGTCP2_ERR_CALLBACK_FAILURE;
    nghttp3_ssize used = nghttp3_conn_read_stream2(q->h3, id, p, n, flags & NGTCP2_STREAM_DATA_FLAG_FIN, ngtcp2_conn_get_timestamp(conn));
    if (used < 0) {
        set_app_error(q, (int)used);
        return NGTCP2_ERR_CALLBACK_FAILURE;
    }
    consume(q, id, (size_t)used);
    return 0;
}

static int acked_stream_data_offset(ngtcp2_conn *conn, int64_t id, uint64_t offset, uint64_t n, void *user, void *sud) {
    fc_quic *q = user;
    (void)conn, (void)offset, (void)sud;
    return q->h3 && nghttp3_conn_add_ack_offset(q->h3, id, n) ? NGTCP2_ERR_CALLBACK_FAILURE : 0;
}

static int stream_close(ngtcp2_conn *conn, uint32_t flags, int64_t id, uint64_t rx_code, uint64_t tx_code, void *user, void *sud) {
    fc_quic *q = user;
    (void)conn, (void)sud;
    if (!q->h3) return 0;
    int rv = nghttp3_conn_close_stream2(q->h3, flags, id, rx_code, tx_code);
    if (rv && rv != NGHTTP3_ERR_STREAM_NOT_FOUND) {
        set_app_error(q, rv);
        return NGTCP2_ERR_CALLBACK_FAILURE;
    }
    return 0;
}

static int stream_shut_read(ngtcp2_conn *conn, int64_t id, void *user) {
    fc_quic *q = user;
    (void)conn;
    return q->h3 && nghttp3_conn_shutdown_stream_read(q->h3, id) ? NGTCP2_ERR_CALLBACK_FAILURE : 0;
}

static int stream_reset(ngtcp2_conn *conn, int64_t id, uint64_t final_size, uint64_t code, void *user, void *sud) {
    (void)final_size, (void)code, (void)sud;
    return stream_shut_read(conn, id, user);
}

static int stream_stop_sending(ngtcp2_conn *conn, int64_t id, uint64_t code, void *user, void *sud) {
    (void)code, (void)sud;
    return stream_shut_read(conn, id, user);
}

static int extend_max_stream_data(ngtcp2_conn *conn, int64_t id, uint64_t max_data, void *user, void *sud) {
    fc_quic *q = user;
    (void)conn, (void)max_data, (void)sud;
    return q->h3 && nghttp3_conn_unblock_stream(q->h3, id) ? NGTCP2_ERR_CALLBACK_FAILURE : 0;
}

static void put_addr(ngtcp2_sockaddr_union *u, ngtcp2_socklen *len, int family, const uint8_t *addr, int port) {
    uint8_t *pp;
    memset(u, 0, sizeof *u);
    if (family == 6) {
        u->in6.sin6_family = AF_INET6;
        memcpy(&u->in6.sin6_addr, addr, 16);
        pp = (uint8_t *)&u->in6.sin6_port;
        *len = sizeof u->in6;
    } else {
        u->in.sin_family = AF_INET;
        memcpy(&u->in.sin_addr, addr, 4);
        pp = (uint8_t *)&u->in.sin_port;
        *len = sizeof u->in;
    }
    pp[0] = (uint8_t)(port >> 8);
    pp[1] = (uint8_t)port;
}

void fc_quic_del(fc_quic *q) {
    if (!q) return;
    nghttp3_conn_del(q->h3);
    ngtcp2_conn_del(q->conn);
    SSL_free(q->ssl);
    free_bodies(q);
    free(q);
}

// fc_quic_new takes ownership of ssl (an SSL from src/tls's new_ssl on a context passed to
// ngtcp2_crypto_boringssl_configure_client_context) and frees it, even on failure. family is 4 or 6; addr
// holds 4 or 16 bytes. ztp is fc_quic_0rtt_tp's from the last connection to this server, if any (at most
// 256 bytes). The ClientHello goes out with the first fc_quic_write.
fc_quic *fc_quic_new(SSL *ssl, int family, const uint8_t *addr, int port, int local_port, uint64_t now, uint64_t initial_rtt, const uint8_t *ztp, size_t ztplen, const fc_quic_events *ev) {
    static const ngtcp2_callbacks cb = {
        .client_initial = client_initial,
        .recv_crypto_data = ngtcp2_crypto_recv_crypto_data_cb,
        .encrypt = ngtcp2_crypto_encrypt_cb,
        .decrypt = ngtcp2_crypto_decrypt_cb,
        .hp_mask = ngtcp2_crypto_hp_mask_cb,
        .recv_stream_data = recv_stream_data,
        .acked_stream_data_offset = acked_stream_data_offset,
        .recv_retry = ngtcp2_crypto_recv_retry_cb,
        .rand = rand_cb,
        .update_key = ngtcp2_crypto_update_key_cb,
        .stream_reset = stream_reset,
        .extend_max_stream_data = extend_max_stream_data,
        .delete_crypto_aead_ctx = ngtcp2_crypto_delete_crypto_aead_ctx_cb,
        .delete_crypto_cipher_ctx = ngtcp2_crypto_delete_crypto_cipher_ctx_cb,
        .stream_stop_sending = stream_stop_sending,
        .version_negotiation = ngtcp2_crypto_version_negotiation_cb,
        .recv_rx_key = recv_rx_key,
        .get_new_connection_id2 = new_cid,
        .get_path_challenge_data2 = ngtcp2_crypto_get_path_challenge_data2_cb,
        .stream_close2 = stream_close,
        .tls_early_data_rejected = early_data_rejected,
    };
    fc_quic *q = calloc(1, sizeof *q);
    if (!q) {
        SSL_free(ssl);
        return NULL;
    }
    q->ssl = ssl;
    q->rtt_us = initial_rtt / 1000;
    q->ev = *ev;
    if (ztplen && ztplen <= sizeof q->ztp) memcpy(q->ztp, ztp, q->ztplen = ztplen);
    q->ref.get_conn = get_conn;
    q->ref.user_data = q;
    SSL_set_app_data(ssl, &q->ref);
    ngtcp2_ccerr_default(&q->ccerr);

    ngtcp2_sockaddr_union local, remote;
    ngtcp2_socklen llen, rlen;
    uint8_t any[16] = {0};
    put_addr(&remote, &rlen, family, addr, port);
    put_addr(&local, &llen, family, any, local_port);
    ngtcp2_path_storage_init(&q->ps, &local.sa, llen, &remote.sa, rlen, NULL);

    // Chrome: an 8-byte random destination CID, an empty source CID, 1250-byte datagrams with no path MTU
    // discovery, packet numbers from 1, CUBIC, a 10 s handshake timeout, and the server's cached RTT.
    ngtcp2_cid dcid, scid = {0};
    dcid.datalen = 8;
    uint8_t g;
    if (RAND_bytes(dcid.data, 8) != 1 || RAND_bytes(&g, 1) != 1) {
        fc_quic_del(q);
        return NULL;
    }
    // Chrome offers QUIC v1 plus a GREASE version (0x?a?a?a?a) in version_information.
    uint32_t versions[2] = {NGTCP2_PROTO_VER_V1, 0x0a0a0a0a | (g & 0xf0u) * 0x01010101u};
    ngtcp2_settings s;
    ngtcp2_settings_default(&s);
    s.initial_ts = now;
    s.initial_rtt = initial_rtt ? initial_rtt : 100 * NGTCP2_MILLISECONDS;
    s.cc_algo = NGTCP2_CC_ALGO_CUBIC;
    s.max_tx_udp_payload_size = 1250;
    s.no_tx_udp_payload_size_shaping = 1;
    s.no_pmtud = 1;
    s.handshake_timeout = 10 * NGTCP2_SECONDS;
    s.max_window = 15728640;
    s.max_stream_window = 6291456;
    s.available_versions = versions;
    s.available_versionslen = 2;
    s.initial_pkt_num = 1;
    ngtcp2_transport_params p;
    chrome_params(&p);
    if (ngtcp2_conn_client_new(&q->conn, &dcid, &scid, &q->ps.path, NGTCP2_PROTO_VER_V1, &cb, &s, &p, NULL, q)) {
        fc_quic_del(q);
        return NULL;
    }
    ngtcp2_conn_set_tls_native_handle(q->conn, ssl);
    return q;
}

static int fail(fc_quic *q, int rv) {
    if (!q->failed && rv == NGTCP2_ERR_CRYPTO) ngtcp2_ccerr_set_tls_alert(&q->ccerr, ngtcp2_conn_get_tls_alert(q->conn), NULL, 0);
    else if (!q->failed) ngtcp2_ccerr_set_liberr(&q->ccerr, rv, NULL, 0);
    q->failed = 1;
    return rv;
}

// fc_quic_read takes one datagram from the peer. A negative ngtcp2 error ends the connection: send
// fc_quic_close_packet's datagram, if any, then delete it.
int fc_quic_read(fc_quic *q, const uint8_t *pkt, size_t n, uint64_t now) {
    ngtcp2_pkt_info pi = {0};
    int rv = ngtcp2_conn_read_pkt(q->conn, &q->ps.path, &pi, pkt, n, now);
    return rv ? fail(q, rv) : 0;
}

// fc_quic_write writes the next datagram into buf (cap at least 1250): its length, 0 when nothing is due
// (including when pacing holds the rest of a burst back until fc_quic_expiry), or a negative error as for
// fc_quic_read. Same loop as ngtcp2's examples/http3_client_proto_codec.cc write_pkt.
ngtcp2_ssize fc_quic_write(fc_quic *q, uint8_t *buf, size_t cap, uint64_t now) {
    ngtcp2_ssize n;
    for (;;) {
        int64_t id = -1;
        int fin = 0;
        nghttp3_vec vec[16];
        nghttp3_ssize nvec = 0;
        if (q->h3 && ngtcp2_conn_get_max_data_left2(q->conn)) {
            nvec = nghttp3_conn_writev_stream(q->h3, &id, &fin, vec, 16);
            if (nvec < 0) {
                set_app_error(q, (int)nvec);
                return NGTCP2_ERR_CALLBACK_FAILURE;
            }
        }
        ngtcp2_ssize used;
        uint32_t flags = NGTCP2_WRITE_STREAM_FLAG_MORE | (fin ? NGTCP2_WRITE_STREAM_FLAG_FIN : 0);
        n = ngtcp2_conn_writev_stream(q->conn, NULL, NULL, buf, cap, &used, flags, id, (const ngtcp2_vec *)vec, (size_t)nvec, now);
        if (n == NGTCP2_ERR_STREAM_DATA_BLOCKED) {
            nghttp3_conn_block_stream(q->h3, id);
            continue;
        }
        if (n == NGTCP2_ERR_STREAM_SHUT_WR) {
            nghttp3_conn_shutdown_stream_write(q->h3, id);
            continue;
        }
        if (n < 0 && n != NGTCP2_ERR_WRITE_MORE) return fail(q, (int)n);
        if (used >= 0) {
            int rv = nghttp3_conn_add_write_offset(q->h3, id, (uint64_t)used);
            if (rv) {
                set_app_error(q, rv);
                return NGTCP2_ERR_CALLBACK_FAILURE;
            }
        }
        if (n != NGTCP2_ERR_WRITE_MORE) break;
    }
    if (n > 0 && (q->burst += (size_t)n) < ngtcp2_conn_get_send_quantum2(q->conn)) return n;
    ngtcp2_conn_update_pkt_tx_time(q->conn, now);
    q->burst = 0;
    return n;
}

// fc_quic_expiry is when fc_quic_handle_expiry is next due (loss detection, ACKs, pacing, idle and handshake
// timeouts), in the same nanosecond clock as now; UINT64_MAX for never.
uint64_t fc_quic_expiry(fc_quic *q) { return ngtcp2_conn_get_expiry(q->conn); }

int fc_quic_handle_expiry(fc_quic *q, uint64_t now) {
    int rv = ngtcp2_conn_handle_expiry(q->conn, now);
    return rv ? fail(q, rv) : 0;
}

// fc_quic_close_packet writes the datagram that ends the connection: the failure's CONNECTION_CLOSE, or
// H3_NO_ERROR when nothing failed. 0 when none may be sent (idle timeout, draining, stateless reset).
ngtcp2_ssize fc_quic_close_packet(fc_quic *q, uint8_t *buf, size_t cap, uint64_t now) {
    if (!q->failed) ngtcp2_ccerr_set_application_error(&q->ccerr, NGHTTP3_H3_NO_ERROR, NULL, 0);
    q->failed = 1;
    if (ngtcp2_conn_in_closing_period(q->conn) || ngtcp2_conn_in_draining_period(q->conn)) return 0;
    ngtcp2_ssize n = ngtcp2_conn_write_connection_close(q->conn, NULL, NULL, buf, cap, &q->ccerr, now);
    return n > 0 ? n : 0;
}

typedef struct fc_field {
    const uint8_t *name;
    size_t nlen;
    const uint8_t *value;
    size_t vlen;
} fc_field;

// fc_quic_submit starts a request: n header fields in send order (pseudo-headers first) and a body, both
// copied, then a PRIORITY_UPDATE carrying prio (an RFC 9218 field value) when plen > 0. Returns 0 and the
// stream id; NGTCP2_ERR_STREAM_ID_BLOCKED while the server allows no more streams; else another error.
int fc_quic_submit(fc_quic *q, const fc_field *f, size_t n, const uint8_t *body, size_t blen, const uint8_t *prio, size_t plen, int64_t *id) {
    static const nghttp3_data_reader dr = {h3_read_body};
    nghttp3_nv nv[64];
    if (!q->h3 || n > 64) return NGTCP2_ERR_INVALID_ARGUMENT;
    for (size_t i = 0; i < n; i++) nv[i] = (nghttp3_nv){f[i].name, f[i].value, f[i].nlen, f[i].vlen, NGHTTP3_NV_FLAG_NONE};
    fc_body *b = NULL;
    if (blen) {
        if (!(b = malloc(sizeof *b + blen))) return NGTCP2_ERR_NOMEM;
        b->prev = NULL;
        b->n = blen;
        b->sent = 0;
        memcpy(b->p, body, blen);
    }
    int rv = ngtcp2_conn_open_bidi_stream(q->conn, id, NULL);
    if (!rv && (rv = nghttp3_conn_submit_request(q->h3, *id, nv, n, b ? &dr : NULL, b))) {
        ngtcp2_conn_shutdown_stream(q->conn, 0, *id, NGHTTP3_H3_INTERNAL_ERROR);
    }
    if (rv) {
        free(b);
        return rv;
    }
    if (b) {
        b->next = q->bodies;
        if (q->bodies) q->bodies->prev = b;
        q->bodies = b;
    }
    if (plen) nghttp3_conn_set_client_stream_priority(q->h3, *id, prio, plen);
    return 0;
}

// fc_quic_cancel abandons a request, resetting both directions with H3_REQUEST_CANCELLED.
void fc_quic_cancel(fc_quic *q, int64_t id) { ngtcp2_conn_shutdown_stream(q->conn, 0, id, NGHTTP3_H3_REQUEST_CANCELLED); }

// fc_quic_ready: 0 while HTTP/3 is not set up, 1 while it runs in 0-RTT (replay-safe requests only), 2 once the
// handshake is done (the certificate passed src/tls's checks).
int fc_quic_ready(fc_quic *q) { return !q->h3 ? 0 : ngtcp2_conn_get_handshake_completed(q->conn) ? 2 : 1; }

// fc_quic_0rtt_tp writes the server's transport parameters that the next connection's 0-RTT needs; 0 before the
// handshake is done.
size_t fc_quic_0rtt_tp(fc_quic *q, uint8_t *buf, size_t cap) {
    ngtcp2_ssize n = ngtcp2_conn_get_handshake_completed(q->conn) ? ngtcp2_conn_encode_0rtt_transport_params2(q->conn, buf, cap) : 0;
    return n > 0 ? (size_t)n : 0;
}

// fc_quic_tp is the transport parameters q's ClientHello carried; valid until fc_quic_del.
const uint8_t *fc_quic_tp(fc_quic *q, size_t *n) {
    *n = q->tplen;
    return q->tp;
}

uint64_t fc_quic_srtt(fc_quic *q) {
    ngtcp2_conn_info ci;
    ngtcp2_conn_get_conn_info(q->conn, &ci);
    return ci.smoothed_rtt;
}

// fc_h3_preview writes into buf, for tests, what a new connection's HTTP/3 layer sends before any response:
// n GET requests carrying PRIORITY_UPDATE prio, on streams 0, 4, ..., as records [stream id: 1 byte]
// [length: 2 bytes, big-endian][bytes] in send order. Returns the bytes used, or -1.
ngtcp2_ssize fc_h3_preview(const uint8_t *prio, size_t plen, int n, uint8_t *buf, size_t cap) {
    static const uint8_t m[] = ":method", g[] = "GET", a[] = ":authority", h[] = "discord.com", sc[] = ":scheme", hs[] = "https", pa[] = ":path", sl[] = "/";
    const nghttp3_nv nv[] = {{(uint8_t *)m, (uint8_t *)g, 7, 3, 0}, {(uint8_t *)a, (uint8_t *)h, 10, 11, 0}, {(uint8_t *)sc, (uint8_t *)hs, 7, 5, 0}, {(uint8_t *)pa, (uint8_t *)sl, 5, 1, 0}};
    nghttp3_conn *h3 = NULL;
    size_t used = 0;
    int ok = !h3_new(&h3, NULL, 2, 6, 10);
    for (int i = 0; ok && i < n; i++) {
        ok = !nghttp3_conn_submit_request(h3, 4 * i, nv, 4, NULL, NULL) && !nghttp3_conn_set_client_stream_priority(h3, 4 * i, prio, plen);
    }
    for (int i = 0; ok && i < 64; i++) {
        int64_t id;
        int fin;
        nghttp3_vec vec[16];
        nghttp3_ssize nvec = nghttp3_conn_writev_stream(h3, &id, &fin, vec, 16);
        if (nvec < 0 || id < 0) {
            ok = nvec == 0;
            break;
        }
        size_t len = (size_t)nghttp3_vec_len(vec, (size_t)nvec);
        if (used + 3 + len > cap) ok = 0;
        else if (len) {
            buf[used] = (uint8_t)id, buf[used + 1] = (uint8_t)(len >> 8), buf[used + 2] = (uint8_t)len;
            used += 3;
            for (nghttp3_ssize j = 0; j < nvec; j++) memcpy(buf + used, vec[j].base, vec[j].len), used += vec[j].len;
        }
        ok = ok && !nghttp3_conn_add_write_offset(h3, id, len);
    }
    nghttp3_conn_del(h3);
    return ok ? (ngtcp2_ssize)used : -1;
}
