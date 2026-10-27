// transport_probe: GETs through discord's Transport (pooling, h2, QUIC race, content decoding).
#import "Basic";
#import "fc";
thread :: #import "fc_thread";
dc :: #import "discord";
http :: #import "http";
main :: () {
    register_thread_context();
    th := thread.create(probe);
    thread.start(th);
    thread.join(th);
}
probe :: (th: *thread.Thread) {
    t: dc.Transport;
    jar: dc.Cookie_Jar;
    dc.cookie_jar_init(*jar);
    dc.transport_init(*t, *jar);
    dc.transport_note_alt_svc(*t, "cdn.discordapp.com", "h3=\":443\"; ma=86400", 0);
    for 1..3 for enc: string.["gzip", "br", "zstd", "gzip, deflate, br, zstd"] {
        hs := make_dynamic(http.Header, 0, 4, temp);
        array_add(*hs, .{"user-agent", "Mozilla/5.0"}, .{"accept-encoding", enc});
        before := tprint("%", hs);
        resp, err := dc.transport_round_trip(*t, "cdn.discordapp.com", .{method = "GET", path = "/detectables/games-v1.json", headers = hs});
        ce, _ := http.header_get(view(resp.headers), "content-encoding");
        print("%: % % status % body % bytes (content-encoding %) headers intact: %\n", enc, resp.version, err, resp.status, resp.body.count, ce, tprint("%", hs) == before);
    }
}
