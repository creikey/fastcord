// HTTP/3 over QUIC: ngtcp2 + nghttp3 through vendor/ngtcp2/fc_ngtcp2.c, TLS from the tls module (Chrome's
// QUIC ClientHello), one UDP socket and one I/O thread per connection.
#import "Basic";
#import "Hash_Table";
#import "Thread";
#import "Atomics";
http :: #import "http";
locks :: #import "locks";
tls :: #import "tls";
lib :: #library,no_dll "../../build/fc_vendor";
#load "quic.jai";
#load "udp.jai";
