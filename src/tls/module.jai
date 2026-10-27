// fastcord's TLS client: a thin binding over vendored BoringSSL (vendor/boringssl) that wraps a netio.Stream
// and exposes one. BoringSSL is configured the way Chrome configures it, so the ClientHello has the shape of
// the official Discord client's (Electron 42 / Chrome 148). Certificates are checked by the OS trust store
// for the server name (trust_*.jai), never by BoringSSL's own verifier.
#import "Basic";
#import "Hash_Table";
#import "Atomics";
locks :: #import "locks";
netio :: #import "netio";
brotli :: #import "brotli";
crypto :: #import "crypto";
#load "boringssl.jai";
#load "tls.jai";
#load "trust_cache.jai";
#if OS == .MACOS #load "trust_darwin.jai";
else #if OS == .WINDOWS #load "trust_windows.jai";
else #if OS == .LINUX #load "trust_linux.jai";
