// fastcord's build of the SQLite amalgamation (vendor/sqlite/sqlite3.c, unmodified), bound in src/sqlite.
// The options are those sqlite.org recommends for applications that embed it.
#define SQLITE_ENABLE_FTS5 1
#define SQLITE_DQS 0
#define SQLITE_THREADSAFE 2
#define SQLITE_DEFAULT_MEMSTATUS 0
#define SQLITE_LIKE_DOESNT_MATCH_BLOBS 1
#define SQLITE_MAX_EXPR_DEPTH 0
#define SQLITE_OMIT_DEPRECATED 1
#define SQLITE_OMIT_LOAD_EXTENSION 1
#define SQLITE_OMIT_SHARED_CACHE 1
#define SQLITE_USE_ALLOCA 1
#include "sqlite3.c"
