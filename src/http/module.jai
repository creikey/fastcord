// HTTP/1.1 (picohttpparser), HTTP/2 (nghttp2) and WebSocket (wslay) clients over netio.Stream, shaped to
// put Chrome's bytes on the wire.
#import "Basic";
#import "String";
#import "Hash_Table";
#import "Base64";
#import "Atomics";
brotli :: #import "brotli";
crypto :: #import "crypto";
inflate :: #import "inflate";
locks :: #import "locks";
netio :: #import "netio";
zstd :: #import "zstd";
vendor :: #library,no_dll "../../build/fc_vendor";
#load "types.jai";
#load "content.jai";
#load "reader.jai";
#load "h1.jai";
#load "h2.jai";
#load "hpack.jai";
#load "ws.jai";
#load "pipe.jai";
