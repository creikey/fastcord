// src/voice/fake_server_test.odin for the Jai voice module. A local fake voice server: WebSocket
// gateway on 127.0.0.1 (plain TCP via Options.dial), UDP media on loopback, and a second DAVE member
// "B" that the server welcomes into our client's group. Verifies the handshake order, IP discovery,
// SELECT_PROTOCOL, heartbeats with seq_ack, the DAVE MLS flow, E2EE media both ways and the close
// code; then a resume after the server drops the connection.
//   jai build.jai - run jai/tests/voice_fake_server.jai && build/voice_fake_server
#import "Basic";
#import "Math";
#import "String";
#import "Thread";
#import "Atomics";
#import "Socket";
#import "POSIX";
voice :: #import "voice";
dave :: #import "voice_dave";
mls :: #import "voice_mls";
http :: #import "http";
netio :: #import "netio";
locks :: #import "locks";

FAKE_USER_A :: cast(u64) 1546819257420087346;
FAKE_USER_B :: cast(u64) 1090123456789012345;
FAKE_CHANNEL :: cast(u64) 1564227670806364345;
FAKE_GUILD :: cast(u64) 1564227669971832975;
FAKE_SSRC_A :: cast(u32) 8597;
FAKE_SSRC_B :: cast(u32) 9001;
FAKE_VIDEO_A :: cast(u32) 8598;  // READY streams[0].ssrc
FAKE_VIDEO_B :: cast(u32) 9002;

// ---------------------------------------------------------------------------
// Sockets and WebSocket frames, server side

// loopback_socket binds a socket to 127.0.0.1 on an ephemeral port.
loopback_socket :: (type: SOCK, proto: IPPROTO, timeout_us := 0) -> s32, int {
    s := socket(AF_INET, type, proto);
    a: sockaddr_in;
    a.sin_len = size_of(sockaddr_in);
    a.sin_family = AF_INET;
    (cast(*[4]u8) *a.sin_addr).* = .[127, 0, 0, 1];
    len: socklen_t = size_of(sockaddr_in);
    bind(s, cast(*sockaddr) *a, len);
    getsockname(s, cast(*sockaddr) *a, *len);
    if type == .STREAM listen(s, 4);
    if timeout_us {
        tv: timeval;
        tv.tv_usec = xx timeout_us;
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, *tv, size_of(timeval));
    }
    return s, port_of(a);
}

port_of :: (a: sockaddr_in) -> u16 {
    p := a.sin_port;
    b := cast(*[2]u8) *p;
    return ((cast(u16) b.*[0]) << 8) | b.*[1];
}

Srv :: struct {
    sock: s32;
    buf: [..]u8;
}

fill :: (s: *Srv, n: int) -> bool {
    tmp: [4096]u8;
    while s.buf.count < n {
        got := recv(s.sock, tmp.data, tmp.count, 0);
        if got <= 0 return false;
        array_add(*s.buf, ..array_view(tmp, 0, got));
    }
    return true;
}

take :: (s: *Srv, n: int) -> []u8 {
    out := array_copy(array_view(s.buf, 0, n),, temp);
    memcpy(s.buf.data, s.buf.data + n, s.buf.count - n);
    s.buf.count -= n;
    return out;
}

// read_frame reads one masked client frame.
read_frame :: (s: *Srv) -> op: u8, payload: []u8, ok: bool {
    if !fill(s, 2) return 0, .[], false;
    h := take(s, 2);
    l := cast(int) (h[1] & 0x7f);
    if l == 126 {
        if !fill(s, 2) return 0, .[], false;
        e := take(s, 2);
        l = ((cast(int) e[0]) << 8) | e[1];
    } else if l == 127 {
        if !fill(s, 8) return 0, .[], false;
        l = 0;
        for take(s, 8) l = (l << 8) | it;
    }
    if !fill(s, 4 + l) return 0, .[], false;
    mk := take(s, 4);
    p := take(s, l);
    for * p it.* ^= mk[it_index % 4];
    return h[0] & 0x0f, p, true;
}

send_frame :: (s: *Srv, op: u8, payload: []u8) {
    hdr: [..]u8;
    hdr.allocator = temp;
    array_add(*hdr, 0x80 | op);
    if payload.count < 126 array_add(*hdr, cast(u8) payload.count);
    else array_add(*hdr, 126, cast(u8) (payload.count >> 8), cast,no_check(u8) payload.count);
    array_add(*hdr, ..payload);
    send(s.sock, hdr.data, xx hdr.count, 0);
}

send_text :: (s: *Srv, text: string) { send_frame(s, 1, cast([]u8) text); }

send_binary :: (s: *Srv, seq: u16, op: u8, payload: []u8) {
    b := NewArray(3 + payload.count, u8,, temp);
    b[0], b[1], b[2] = cast(u8) (seq >> 8), cast,no_check(u8) seq, op;
    memcpy(b.data + 3, payload.data, payload.count);
    send_frame(s, 2, b);
}

// upgrade accepts one connection and answers its WebSocket upgrade; returns the request head.
upgrade :: (listen: s32) -> Srv, head: string, ok: bool {
    s := Srv.{sock = accept(listen, null, null)};
    while !contains(cast(string) s.buf, "\r\n\r\n") if !fill(*s, s.buf.count + 1) return s, "", false;
    end := find_index_from_left(cast(string) s.buf, "\r\n\r\n");
    head := copy_string(to_string(s.buf.data, end));
    key := "";
    for split(head, "\r\n",, temp) if begins_with(it, "Sec-WebSocket-Key:") key = trim(slice(it, 18, it.count - 18));
    take(*s, end + 4);
    resp := tprint("HTTP/1.1 101 Switching Protocols\r\nConnection: upgrade\r\nsec-websocket-accept: %\r\nupgrade: websocket\r\n\r\n", http.ws_accept_for_key(key,, temp));
    send(s.sock, resp.data, xx resp.count, 0);
    return s, head, true;
}

json :: (text: string) -> etf.Value {
    v := etf.from_json(text,, temp);
    return v;
}
etf :: #import "etf";

// ---------------------------------------------------------------------------
// Test 1: the full call

Fake :: struct {
    listen: s32;
    tcp_port: int;
    udp: s32;
    udp_port: int;
    key: [32]u8;
    ext_priv: [mls.NSK]u8;
    ext_raw: []u8;
    b_id: mls.Identity;
    b_kp: mls.Key_Package;
    b_secrets: mls.Key_Package_Secrets;
    b_group: *mls.Group;
    b_ratchet, a_ratchet: dave.Ratchet;
    client_ep: sockaddr_in;
    have_client: bool;
    mu: locks.Mutex;
    stop: bool;
    // results
    request_line, header_names, identify, select_proto: string;
    got_op16, key_package, commit_ok: bool;
    ready_tid: int;
    heartbeats: int;
    last_seq_ack: s64;
    speaking_on: bool;
    rtp_e2ee_ok, rtp_bad, rtcp: int;
    video_ok, video_bad: int;  // A's camera frames that decrypted to the frame sent
    big_first, big_last: Apollo_Time; // when BIG_TS's first and last packets came (the pacer spreads them)
    top_nonce, nonce_back: u32;       // the highest transport nonce seen, and the furthest one came after it
    got_op12, got_op15: bool;
    a_video: voice.Video_Rx;
    close_code: int;
    discovery: bool;
    failure: string;
}

fail :: (f: *Fake, msg: string) {
    locks.guard(*f.mu);
    if !f.failure f.failure = copy_string(msg);
}

// next_message returns the next message that is not a heartbeat, a speaking update or media sink wants (handled here).
next_message :: (f: *Fake, s: *Srv) -> text: string, bin: []u8, is_bin: bool, ok: bool {
    while true {
        op, p, ok := read_frame(s);
        if !ok return "", .[], false, false;
        if op == 8 {
            locks.guard(*f.mu);
            f.close_code = ifx p.count >= 2 then ((cast(int) p[0]) << 8) | p[1] else 1005;
            return "", .[], false, false;
        }
        if op == 2 return "", p, true, true;
        if op != 1 continue;
        v := json(cast(string) p);
        o := voice.jint(voice.jget(v, "op"));
        d := voice.jget(v, "d");
        if o == 3 {
            {
                locks.guard(*f.mu);
                f.heartbeats += 1;
                f.last_seq_ack = voice.jint(voice.jget(d, "seq_ack"));
            }
            send_text(s, tprint("{\"op\":6,\"d\":{\"t\":%}}", voice.jint(voice.jget(d, "t"))));
            continue;
        }
        if o == 5 {
            locks.guard(*f.mu);
            if voice.jint(voice.jget(d, "speaking")) == 1 f.speaking_on = true;
            continue;
        }
        if o == 12 { locks.guard(*f.mu); f.got_op12 = contains(cast(string) p, "\"video_ssrc\":8598"); continue; }
        if o == 15 { locks.guard(*f.mu); f.got_op15 = true; continue; }
        return cast(string) p, .[], false, true;
    }
    return "", .[], false, false;
}

gw_thread :: (t: *Thread) -> s64 {
    f := cast(*Fake) t.data;
    s, head, ok := upgrade(f.listen);
    if !ok { fail(f, "upgrade read"); return 0; }
    defer close(s.sock);
    lines := split(head, "\r\n");
    f.request_line = lines[0];
    names: [..]string;
    for array_view(lines, 1, lines.count - 1) {
        found, name := split_from_left(it, #char ":");
        if found array_add(*names, name);
    }
    f.header_names = join(..names, ",");

    text, _, _, ok2 := next_message(f, *s);
    if !ok2 { fail(f, "no identify"); return 0; }
    f.identify = copy_string(text);
    send_text(*s, "{\"op\":8,\"d\":{\"v\":8,\"heartbeat_interval\":300}}");
    send_text(*s, tprint("{\"op\":2,\"d\":{\"streams\":[{\"type\":\"video\",\"ssrc\":8598,\"rtx_ssrc\":8599,\"rid\":\"100\",\"quality\":100,\"active\":false}],\"ssrc\":%,\"port\":%,\"modes\":[\"aead_aes256_gcm_rtpsize\",\"aead_xchacha20_poly1305_rtpsize\"],\"ip\":\"127.0.0.1\",\"experiments\":[\"fixed_keyframe_interval\"]}}", FAKE_SSRC_A, f.udp_port));
    while true {
        text, _, _, ok2 = next_message(f, *s);
        if !ok2 { fail(f, "no select protocol"); return 0; }
        if !begins_with(text, "{\"op\":16") break;
        f.got_op16 = true;
        send_text(*s, "{\"op\":16,\"d\":{\"voice\":\"0.22.2\",\"rtc_worker\":\"1.7.1\"}}");
    }
    f.select_proto = copy_string(text);
    kb: String_Builder;
    for f.key print_to_builder(*kb, ifx it_index then ",%" else "%", it);
    send_text(*s, tprint("{\"op\":4,\"d\":{\"video_codec\":\"H265\",\"secure_frames_version\":1,\"secret_key\":[%],\"mode\":\"aead_aes256_gcm_rtpsize\",\"media_session_id\":\"m\",\"dave_protocol_version\":1,\"audio_codec\":\"opus\"}}", builder_to_string(*kb,, temp)));
    send_text(*s, tprint("{\"seq\":1,\"op\":11,\"d\":{\"user_ids\":[\"%\"]}}", FAKE_USER_B));
    send_text(*s, tprint("{\"op\":12,\"d\":{\"user_id\":\"%\",\"audio_ssrc\":%,\"video_ssrc\":%,\"streams\":[{\"type\":\"video\",\"ssrc\":%,\"rtx_ssrc\":%,\"active\":true}]}}", FAKE_USER_B, FAKE_SSRC_B, FAKE_VIDEO_B, FAKE_VIDEO_B, FAKE_VIDEO_B + 1));
    send_binary(*s, 2, 25, f.ext_raw);

    // key package (op 26), bare KeyPackage
    _, bin, is_bin, ok3 := next_message(f, *s);
    if !ok3 || !is_bin || bin.count < 2 || bin[0] != 26 { fail(f, "no key package"); return 0; }
    r := mls.reader_make(array_view(bin, 1, bin.count - 1));
    akp := mls.r_key_package(*r);
    if !mls.r_done(*r) || mls.validate_key_package(*akp) != .None { fail(f, "bad key package"); return 0; }
    f.key_package = true;
    gid: [8]u8;
    for 0..7 gid[it] = cast,no_check(u8) (FAKE_CHANNEL >> (56 - 8 * it));
    add, aok := mls.external_proposal(gid, 0, 0, .{type = .Add, add = f.b_kp}, f.ext_priv);
    if !aok { fail(f, "proposal"); return 0; }
    w := mls.writer_make();
    mls.w_u8(*w, 0);
    mls.w_vec(*w, add);
    send_binary(*s, 3, 27, w.buf);

    // commit + welcome (op 28)
    _, bin, is_bin, ok3 = next_message(f, *s);
    if !ok3 || !is_bin || bin[0] != 28 { fail(f, "no commit"); return 0; }
    cr := mls.reader_make(array_view(bin, 1, bin.count - 1));
    commit := mls.r_mls_message_raw(*cr);
    welcome := array_view(bin, 1 + commit.count, bin.count - 1 - commit.count);
    g, jerr := mls.group_join(welcome, .{key_package = *f.b_kp, secrets = *f.b_secrets, sig_priv = f.b_id.sig_priv});
    if jerr != .None { fail(f, tprint("b join: %", jerr)); return 0; }
    bb := dave.sender_base_secret(g, FAKE_USER_B);
    ab := dave.sender_base_secret(g, FAKE_USER_A);
    dave.ratchet_init(*f.b_ratchet, bb);
    dave.ratchet_init(*f.a_ratchet, ab);
    {
        locks.guard(*f.mu);
        f.b_group = g;
        f.commit_ok = true;
    }
    tb := NewArray(2 + commit.count, u8,, temp);
    tb[1] = 1;  // transition id 1
    memcpy(tb.data + 2, commit.data, commit.count);
    send_binary(*s, 4, 29, tb);

    text, _, _, ok2 = next_message(f, *s);
    if !ok2 { fail(f, "no ready"); return 0; }
    v := json(text);
    if voice.jint(voice.jget(v, "op")) == 23 {
        locks.guard(*f.mu);
        f.ready_tid = voice.jint(voice.jget(voice.jget(v, "d"), "transition_id"));
    }
    send_text(*s, "{\"op\":22,\"d\":{\"transition_id\":1},\"seq\":5}");
    send_text(*s, tprint("{\"op\":5,\"d\":{\"user_id\":\"%\",\"ssrc\":%,\"speaking\":1},\"seq\":6}", FAKE_USER_B, FAKE_SSRC_B));
    // keep serving heartbeats until the client closes
    while true {
        _, _, _, more := next_message(f, *s);
        if !more break;
    }
    return 0;
}

udp_thread :: (t: *Thread) -> s64 {
    f := cast(*Fake) t.data;
    buf, plain: [2048]u8;
    tc, tx: voice.Transport_Crypto;
    voice.transport_init(*tc, .Aes256_Gcm_Rtpsize, f.key);
    voice.transport_init(*tx, .Aes256_Gcm_Rtpsize, f.key);
    defer { voice.transport_reset(*tc); voice.transport_reset(*tx); }
    seq, vseq: u16 = 1, 500;
    ts, vts, nonce, dnonce: u32;
    next_send := current_time_monotonic();
    while !atomic_load(*f.stop) {
        from: sockaddr_in;
        flen: socklen_t = size_of(sockaddr_in);
        n := recvfrom(f.udp, buf.data, buf.count, 0, cast(*sockaddr) *from, *flen);
        if n > 0 {
            pkt := array_view(buf, 0, n);
            h, hok := voice.parse_rtp_header(pkt);
            discovery := n == voice.DISCOVERY_LEN && voice.get_u16(pkt) == 1;
            if !discovery && n >= 4 {
                // seal and send aren't one step, so the mic or RTCP may pass a video packet by one or two;
                // queued video sealed early would fall a whole keyframe behind (the SFU drops it)
                nonce := voice.get_u32(pkt, n - 4);
                locks.guard(*f.mu);
                if nonce > f.top_nonce f.top_nonce = nonce;
                else f.nonce_back = max(f.nonce_back, f.top_nonce - nonce);
            }
            if discovery {
                resp: [voice.DISCOVERY_LEN]u8;
                voice.build_discovery_response(resp, voice.get_u32(pkt, 4), "127.0.0.1", port_of(from));
                sendto(f.udp, resp.data, resp.count, 0, cast(*sockaddr) *from, flen);
                locks.guard(*f.mu);
                f.client_ep = from;
                f.have_client = true;
                f.discovery = true;
            } else if voice.is_rtcp(pkt) {
                m, ok := voice.transport_open(*tc, pkt, 8, plain);
                _, rok := voice.parse_report(array_view(plain, 0, m));
                if ok && rok {
                    locks.guard(*f.mu);
                    f.rtcp += 1;
                }
            } else if hok && h.ssrc == FAKE_VIDEO_A {
                m, ok := voice.transport_open(*tc, pkt, h.aad_len, plain);
                if ok && h.pt == 103 && h.ts == BIG_TS {
                    locks.guard(*f.mu);
                    if !f.big_first f.big_first = current_time_monotonic();
                    f.big_last = current_time_monotonic();
                } else if ok && h.pt == 103 {
                    au, done := voice.rx_video_packet(*f.a_video, .H265, h.seq, h.ts, h.marker, array_view(plain, h.payload_off, m - h.payload_off));
                    if done {
                        p, pok := dave.parse_protocol_frame(au);
                        k, kok := dave.ratchet_get(*f.a_ratchet, p.nonce >> 24);
                        out := NewArray(au.count, u8,, temp);
                        fl: int;
                        dok: bool;
                        if pok && kok fl, dok = dave.decrypt_frame(k, *p, out);
                        want, _ := voice.with_long_start_codes(fake_video_au());
                        locks.guard(*f.mu);
                        if dok && fl == want.count && memcmp(out.data, want.data, fl) == 0 f.video_ok += 1;
                        else f.video_bad += 1;
                    }
                }
            } else if hok {
                m, ok := voice.transport_open(*tc, pkt, h.aad_len, plain);
                good := false;
                locks.lock(*f.mu);
                bg := f.b_group;
                locks.unlock(*f.mu);
                if ok && h.ssrc == FAKE_SSRC_A && bg {
                    p, pok := dave.parse_protocol_frame(array_view(plain, h.payload_off, m - h.payload_off));
                    k, kok := dave.ratchet_get(*f.a_ratchet, p.nonce >> 24);
                    out: [2048]u8;
                    if pok && kok {
                        fl, dok := dave.decrypt_frame(k, *p, out);
                        good = dok && fl == 3 && out[0] == 0xF8;
                    }
                }
                locks.guard(*f.mu);
                if good f.rtp_e2ee_ok += 1;
                else f.rtp_bad += 1;
            }
        }
        // B talks: one DAVE + transport encrypted Opus frame every 20 ms
        locks.lock(*f.mu);
        have := f.have_client && f.b_group && f.ready_tid == 1;
        ep := f.client_ep;
        locks.unlock(*f.mu);
        if have && to_nanoseconds(current_time_monotonic() - next_send) >= 0 {
            next_send += milliseconds_to_apollo(20);
            k := dave.ratchet_get(*f.b_ratchet, dnonce >> 24);
            frame: [64]u8;
            fl := dave.encrypt_opus_frame(k, dnonce, u8.[0xFC, 0x01, 0x02, 0x03, 0x04], frame);
            dnonce += 1;
            rp: [128]u8;
            pl, aad := voice.build_audio_rtp(rp, seq, ts, FAKE_SSRC_B, 20, true, array_view(frame, 0, fl));
            sealed: [200]u8;
            sl := voice.transport_seal(*tx, array_view(rp, 0, pl), aad, nonce, sealed);
            nonce += 1;
            seq += 1;
            ts += 960;
            sendto(f.udp, sealed.data, xx sl, 0, cast(*sockaddr) *ep, size_of(sockaddr_in));
            // and every 5th tick a camera frame (H.265, as SESSION_DESCRIPTION chose), in RTP
            if seq % 5 == 0 {
                frame, nals := voice.with_long_start_codes(fake_video_au());
                enc := NewArray(frame.count + 256, u8,, temp);
                vk := dave.ratchet_get(*f.b_ratchet, dnonce >> 24);
                el := dave.encrypt_frame(vk, dnonce, frame, voice.dave_clear_ranges(.H265, frame, nals), enc);
                dnonce += 1;
                V :: struct { f: *Fake; tx: *voice.Transport_Crypto; nonce: *u32; seq: *u16; ts: u32; ep: sockaddr_in; }
                v := V.{f, *tx, *nonce, *vseq, vts, ep};
                voice.packetize(.H265, array_view(enc, 0, el), nals, (payload: []u8, last: bool, data: *void) {
                    v := cast(*V) data;
                    rp: [1300]u8;
                    rp[0] = 0x80;
                    rp[1] = 103 | (ifx last then cast(u8) 0x80 else 0);
                    voice.put_u16(rp, v.seq.*, 2);
                    voice.put_u32(rp, v.ts, 4);
                    voice.put_u32(rp, FAKE_VIDEO_B, 8);
                    memcpy(rp.data + 12, payload.data, payload.count);
                    sealed: [1400]u8;
                    sl := voice.transport_seal(v.tx, array_view(rp, 0, 12 + payload.count), 12, v.nonce.*, sealed);
                    v.nonce.* += 1;
                    v.seq.* += 1;
                    sendto(v.f.udp, sealed.data, xx sl, 0, cast(*sockaddr) *v.ep, size_of(sockaddr_in));
                }, *v);
                vts += 9000;
            }
        }
        reset_temporary_storage();
    }
    return 0;
}

g_capture_phase: float64;
g_playback_b: int;
g_video_b: int;
BIG_TS :: 99_000;

// An H.265 keyframe: VPS, SPS, PPS and a 3000-byte IDR slice (fragmented in RTP).
fake_video_au :: () -> []u8 {
    b: [..]u8;
    b.allocator = temp;
    for hdr: ([2]u8).[.[0x40, 0x01], .[0x42, 0x01], .[0x44, 0x01], .[0x26, 0x01]] {
        array_add(*b, 0, 0, 0, 1);
        array_add(*b, ..hdr);
        for 0..ifx hdr[0] == 0x26 then 2999 else 9 array_add(*b, cast(u8) (it * 13 + 5));
    }
    return b;
}

plain_dial :: (host: string, port: int) -> netio.Stream, bool {
    tcp, err := netio.dial_tcp(host, port);
    if err != .None return .{}, false;
    return netio.tcp_stream(tcp), true;
}

failures := 0;
expect :: (ok: bool, what: string, args: ..Any) {
    if ok return;
    print("FAIL: %\n", tprint(what, ..args));
    failures += 1;
}

run_threads :: (data: *void, procs: ..Thread_Proc) -> []Thread {
    threads := NewArray(procs.count, Thread);
    for * threads {
        thread_init(it, procs[it_index]);
        it.data = data;
        thread_start(it);
    }
    return threads;
}

join_threads :: (threads: []Thread) { for * threads { thread_is_done(it, -1); thread_deinit(it); } }

test_fake_voice_server :: () {
    f := New(Fake);
    for * f.key it.* = xx (it_index + 1);
    pub: [mls.NPK]u8;
    f.ext_priv, pub = mls.generate_signature_key();
    w := mls.writer_make(context.allocator);
    mls.w_external_sender(*w, .{signature_key = pub, credential = .{mls.CRED_BASIC, .[0]}});
    f.ext_raw = w.buf;
    f.b_id.sig_priv, f.b_id.sig_pub = mls.generate_signature_key();
    bid := NewArray(8, u8);
    for 0..7 bid[it] = cast,no_check(u8) (FAKE_USER_B >> (56 - 8 * it));
    f.b_id.credential = .{mls.CRED_BASIC, bid};
    _, f.b_kp, f.b_secrets = mls.key_package_create(*f.b_id);
    f.listen, f.tcp_port = loopback_socket(.STREAM, .TCP);
    f.udp, f.udp_port = loopback_socket(.DGRAM, .UDP, timeout_us = 5_000);
    threads := run_threads(f, gw_thread, udp_thread);

    voice.set_codec(voice.stub_codec());
    opts := voice.Options.{
        dial = plain_dial,
        no_audio_devices = true,
        capture = (data: *void, out: []float32) -> int {
            for * out {
                it.* = cast(float32) (0.3 * sin(g_capture_phase));
                g_capture_phase += 2 * PI * 440 / 48000;
            }
            return out.count;
        },
        playback = (data: *void, user_id: u64, pcm: []float32) { if user_id == FAKE_USER_B atomic_add(*g_playback_b, 1); },
        video = (data: *void, user_id: u64, codec: voice.Video_Codec, au: []u8, keyframe: bool) {
            want, _ := voice.with_long_start_codes(fake_video_au());
            if user_id == FAKE_USER_B && codec == .H265 && keyframe && au.count == want.count && memcmp(au.data, want.data, au.count) == 0 atomic_add(*g_video_b, 1);
        },
    };
    c := voice.voice_connect(.{endpoint = tprint("127.0.0.1:%", f.tcp_port), token = "TOKEN", guild_or_channel_id = FAKE_GUILD,
        user_id = FAKE_USER_A, session_id = "SESSION", channel_id = FAKE_CHANNEL}, opts);
    expect(voice.wait_state(c, .Connected, 5000), "connected");
    sleep_milliseconds(1800);

    st := voice.e2ee_status(c,, temp);
    expect(st.active && st.protocol_version == 1 && st.epoch == 1, "e2ee active");
    if f.b_group {
        auth := mls.epoch_authenticator(f.b_group);
        want := dave.privacy_code(auth,, temp);
        expect(st.privacy_code == want, "privacy code matches peer");
    }
    speakers := voice.speaking_users(c,, temp);
    expect(array_find(speakers, FAKE_USER_A) && array_find(speakers, FAKE_USER_B), "speaking indicators for self and peer");
    stats := voice.get_stats(c);
    expect(stats.ws_ping_ms >= 0 && stats.packets_sent > 20 && stats.packets_received > 20, "media stats %", stats);
    vc, vok := voice.verification_code(c, FAKE_USER_B,, temp);
    expect(vok && vc.count == 45, "verification code");
    // our camera: op 12, then frames
    voice.set_video(c, true, 640, 360, 30, 1_000_000);
    for 1..10 {
        voice.send_video(c, voice.video_codec(c), fake_video_au(), cast(u32) (it * 3000));
        reset_temporary_storage();
        sleep_milliseconds(30);
    }
    // a 100 KB keyframe at 1 Mb/s leaves paced at 2.5x: about 320 ms, not one burst
    big: [..]u8;
    big.allocator = temp;
    array_add(*big, ..fake_video_au());
    for 0..100_000 array_add(*big, cast(u8) (it * 7 + 1));
    voice.send_video(c, voice.video_codec(c), big, BIG_TS);
    sleep_milliseconds(600);
    span := to_milliseconds(f.big_last - f.big_first);
    expect(span >= 200 && span <= 500, "a keyframe paced over % ms", span);
    expect(f.nonce_back <= 4, "transport nonces in send order (one came % behind)", f.nonce_back);
    expect(atomic_load(*g_video_b) >= 3, "B's camera frames decoded: %", g_video_b);

    voice.voice_disconnect(c);
    sleep_milliseconds(100);
    atomic_store(*f.stop, true);
    join_threads(threads);
    close(f.listen);
    close(f.udp);

    expect(f.failure == "", "server failure: %", f.failure);
    expect(f.request_line == "GET /?v=9 HTTP/1.1", "request line %", f.request_line);
    expect(f.header_names == "Host,Connection,Pragma,Cache-Control,User-Agent,Upgrade,Origin,Sec-WebSocket-Version,Accept-Encoding,Accept-Language,Sec-WebSocket-Key,Sec-WebSocket-Extensions", "header order %", f.header_names);
    expect(begins_with(f.identify, "{\"op\":0,\"d\":{\"server_id\":\"1564227669971832975\",\"channel_id\":\"1564227670806364345\",\"user_id\":\"1546819257420087346\",\"session_id\":\"SESSION\",\"token\":\"TOKEN\",\"max_dave_protocol_version\":1"), "identify");
    expect(f.got_op16, "op 16 after READY");
    expect(f.discovery, "ip discovery");
    expect(contains(f.select_proto, "\"data\":{\"address\":\"127.0.0.1\",\"port\":") && contains(f.select_proto, "\"mode\":\"aead_aes256_gcm_rtpsize\""), "select protocol");
    expect(f.key_package && f.commit_ok && f.ready_tid == 1, "DAVE MLS flow");
    expect(f.heartbeats >= 3 && f.last_seq_ack == 6, "heartbeats with seq_ack (% beats, seq_ack %)", f.heartbeats, f.last_seq_ack);
    expect(f.speaking_on, "op 5 speaking");
    expect(f.rtp_e2ee_ok > 20, "E2EE rtp from client: ok=% bad=%", f.rtp_e2ee_ok, f.rtp_bad);
    expect(f.rtcp >= 1, "rtcp report");
    expect(f.got_op15 && f.got_op12, "op 15 media sink wants, op 12 video");
    expect(f.video_ok >= 9 && f.video_bad == 0, "E2EE video from client: ok=% bad=%", f.video_ok, f.video_bad);
    expect(f.close_code == voice.CLOSE_FORCE, "close code %", f.close_code);
    expect(atomic_load(*g_playback_b) > 20, "played B's audio: %", g_playback_b);
}

// ---------------------------------------------------------------------------
// Test 2: resume. The server closes with 4014 (disconnected: kicked or moved) after
// SESSION_DESCRIPTION; like RTCControlSocket the client must reconnect and send RESUME (op 7) with
// seq_ack, then accept RESUMED (op 9) and be Connected again without a new IDENTIFY. The server then
// closes with 4006 (session no longer valid), which ends the connection without a retry.

Resume_Fake :: struct {
    listen, udp: s32;
    udp_port: int;
    stop: bool;
    resume_msg: string;
    failure: string;
}

// next_text returns the next text frame that is not a heartbeat.
next_text :: (s: *Srv) -> string, bool {
    while true {
        op, p, ok := read_frame(s);
        if !ok || op == 8 return "", false;
        if op == 1 && !begins_with(cast(string) p, "{\"op\":3") return cast(string) p, true;
    }
    return "", false;
}

resume_gw :: (t: *Thread) -> s64 {
    f := cast(*Resume_Fake) t.data;
    s, _, ok := upgrade(f.listen);
    if !ok { f.failure = "upgrade 1"; return 0; }
    next_text(*s);  // identify
    send_text(*s, "{\"op\":8,\"d\":{\"v\":8,\"heartbeat_interval\":5000}}");
    send_text(*s, tprint("{\"op\":2,\"d\":{\"ssrc\":77,\"port\":%,\"modes\":[\"aead_xchacha20_poly1305_rtpsize\"],\"ip\":\"127.0.0.1\",\"experiments\":[]}}", f.udp_port));
    while true {
        m, mok := next_text(*s);
        if !mok { f.failure = "no select"; break; }
        if begins_with(m, "{\"op\":1,") break;
    }
    send_text(*s, "{\"op\":4,\"d\":{\"secret_key\":[7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7],\"mode\":\"aead_xchacha20_poly1305_rtpsize\",\"dave_protocol_version\":1,\"audio_codec\":\"opus\"},\"seq\":3}");
    sleep_milliseconds(200);
    send_frame(*s, 8, u8.[0x0f, 0xae]);  // close 4014
    close(s.sock);

    s2, _, ok2 := upgrade(f.listen);
    if !ok2 { f.failure = "upgrade 2"; return 0; }
    defer close(s2.sock);
    m, mok := next_text(*s2);
    if mok f.resume_msg = copy_string(m);
    send_text(*s2, "{\"op\":9,\"d\":null}");
    sleep_milliseconds(300);
    send_frame(*s2, 8, u8.[0x0f, 0xa6]);  // close 4006: not resumable
    while true {
        _, more := next_text(*s2);
        if !more break;
    }
    return 0;
}

resume_udp :: (t: *Thread) -> s64 {
    f := cast(*Resume_Fake) t.data;
    buf: [2048]u8;
    while !atomic_load(*f.stop) {
        from: sockaddr_in;
        len: socklen_t = size_of(sockaddr_in);
        n := recvfrom(f.udp, buf.data, buf.count, 0, cast(*sockaddr) *from, *len);
        if n != voice.DISCOVERY_LEN continue;
        resp: [voice.DISCOVERY_LEN]u8;
        voice.build_discovery_response(resp, voice.get_u32(buf, 4), "127.0.0.1", port_of(from));
        sendto(f.udp, resp.data, resp.count, 0, cast(*sockaddr) *from, len);
    }
    return 0;
}

test_fake_voice_resume :: () {
    f := New(Resume_Fake);
    port: int;
    f.listen, port = loopback_socket(.STREAM, .TCP);
    f.udp, f.udp_port = loopback_socket(.DGRAM, .UDP, timeout_us = 20_000);
    voice.set_codec(voice.stub_codec());
    threads := run_threads(f, resume_gw, resume_udp);
    c := voice.voice_connect(.{endpoint = tprint("127.0.0.1:%", port), token = "TK", guild_or_channel_id = 5, user_id = 6, session_id = "SS", channel_id = 7},
        .{dial = plain_dial, no_audio_devices = true});
    expect(voice.wait_state(c, .Connected, 3000), "first connect");
    expect(voice.wait_state(c, .Resuming, 3000), "resuming after drop");
    expect(voice.wait_state(c, .Connected, 5000), "resumed after 4014");
    expect(voice.get_stats(c).reconnects == 1, "one reconnect");
    expect(voice.wait_state(c, .Disconnected, 3000), "4006 ends the connection");
    _, code := voice.state(c);
    expect(code == voice.CLOSE_INVALID_SESSION && voice.get_stats(c).reconnects == 1, "close % without a retry", code);
    voice.voice_disconnect(c);
    atomic_store(*f.stop, true);
    join_threads(threads);
    close(f.listen);
    close(f.udp);
    expect(f.failure == "", "server: %", f.failure);
    expect(f.resume_msg == "{\"op\":7,\"d\":{\"token\":\"TK\",\"session_id\":\"SS\",\"server_id\":\"5\",\"channel_id\":\"7\",\"seq_ack\":3}}", "resume: %", f.resume_msg);
}

main :: () {
    test_fake_voice_server();
    test_fake_voice_resume();
    if failures exit(1);
    print("voice fake server tests ok\n");
}
