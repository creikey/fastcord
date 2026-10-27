// net_probe: one HTTPS GET over the real stack (netio -> tls -> h2) to a neutral host; `net_probe h3` does
// HTTP/3 over QUIC instead.
#import "Basic";
netio :: #import "netio";
tls :: #import "tls";
http :: #import "http";
quic :: #import "quic";

main :: () {
    if get_command_line_arguments().count > 1 { h3(); return; }
    host := "example.com";
    s, err := netio.dial_tcp(host, 443);
    print("dial: %\n", err);
    if err != .None return;
    t, terr, detail := tls.connect(netio.tcp_stream(s), .{alpn = string.["h2", "http/1.1"], server_name = host});
    print("tls: % (detail %) alpn %\n", terr, detail, ifx t then tls.negotiated_alpn(t) else "");
    if !t return;
    c, herr := http.h2_connect(tls.stream(t));
    print("h2 connect: %\n", herr);
    if !c return;
    resp, rerr := http.h2_request(c, .{method = "GET", scheme = "https", authority = host, path = "/"});
    print("h2 request: % status % body % bytes\n", rerr, resp.status, resp.body.count);
    http.response_destroy(*resp);
    http.h2_close(c);
}

// HTTP/3 over QUIC: Cloudflare serves h3 on its own site.
h3 :: () {
    c, err := quic.connect("cloudflare.com");
    print("quic connect: %\n", err);
    if !c return;
    resp, rerr := quic.request(c, .{method = "GET", scheme = "https", authority = "cloudflare.com", path = "/cdn-cgi/trace"});
    print("h3 request: % status % body % bytes\n", rerr, resp.status, resp.body.count);
    http.response_destroy(*resp);
    quic.close(c);
}
