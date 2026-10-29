// Chrome's choice between HTTP/2 (TCP) and HTTP/3 (QUIC) for an origin:
//   - First contact uses TCP. Alt-Svc response headers (h3=":443"; ma=N) are recorded with their expiry
//     and persisted to disk.
//   - Later connects race: the QUIC job starts at once; the TCP job starts immediately, or 1.5 x the cached
//     RTT later if QUIC is known to work on this network (Chrome's delay_main_job). The first to succeed
//     wins.
//   - If QUIC fails while TCP works, the alternative is marked broken for 5 minutes, doubling per failure
//     up to 2 days (BrokenAlternativeServices), and TCP is used meanwhile.
//   - An established h3 connection is reused for the origin while it is open (Chrome keeps one QUIC
//     session per origin; it idles out after 30s).
#import "Basic";
#import "String";
#import "Hash_Table";
#import "Thread";
#import "File";
File_Utilities :: #import "File_Utilities";
locks :: #import "locks";
quic :: #import "quic";
#load "altsvc.jai";
