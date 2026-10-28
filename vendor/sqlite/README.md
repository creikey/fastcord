# SQLite

Self-hosted servers keep everything in one SQLite file (`src/serve`); the client database comes later.
Upstream's amalgamation, unmodified: `sqlite3.c` and `sqlite3.h`.

- Source: https://sqlite.org/2026/sqlite-amalgamation-3540100.zip (SQLite 3.54.1)
- SHA3-256 of the zip (as published on sqlite.org/download.html): 92281c86e2957f9b9305890f9ac04204caa7b677cc868dc326d942689df28e30
- sha256 of the zip: 0a9c8e34352dad46006aa82836d5383bff9dc6bc9ce5a60553c05aa30e6ad1f9
- Licence: public domain (see the header of `sqlite3.c`).

`fc_sqlite.c` is ours: it sets the compile options (FTS5, no double-quoted strings, multi-thread mode, no
extension loading or shared cache) and includes `sqlite3.c`. Bound in `src/sqlite`.

To update: replace both files with the new amalgamation, record the version and hashes here, then build
and run `src/tests/serve.jai`.
