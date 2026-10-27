// net_probe: one HTTPS GET over the real stack (netio -> tls -> h2) to a neutral host.
#import "Basic";
#import "fc";
netio :: #import "netio";
tls :: #import "tls";
http :: #import "http";
main :: () {
	register_thread_context();
    if get_command_line_arguments().count > 1 { h3(); return; }
    host := "example.com";
    s, err := netio.dial_tcp(host, 443);
    print("dial: %\n", err);
    if err != .None return;
    t, terr := tls.connect(netio.tcp_stream(s), .{alpn = string.["h2", "http/1.1"], server_name = host});
    print("tls: % (detail %) alpn %\n", terr, tls.last_error(), ifx t then tls.negotiated_alpn(t) else "");
    if !t return;
    c, herr := http.h2_connect(tls.stream(t));
    print("h2 connect: %\n", herr);
    if !c return;
    resp, rerr := http.h2_request(c, .{method = "GET", scheme = "https", authority = "example.com", path = "/"});
    print("h2 request: % status % body % bytes\n", rerr, resp.status, resp.body.count);
}

// HTTP/3 over QUIC (net_probe h3): Cloudflare serves h3 on its own site.
quic :: #import "quic";
h3 :: () {
    c, err := quic.connect("cloudflare.com");
    print("quic connect: %\n", err);
    if !c return;
    resp, rerr := quic.request(c, .{method = "GET", scheme = "https", authority = "cloudflare.com", path = "/cdn-cgi/trace"});
    print("h3 request: % status % body % bytes\n", rerr, resp.status, resp.body.count);
}
